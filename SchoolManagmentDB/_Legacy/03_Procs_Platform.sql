/*==============================================================================
  03_Procs_Platform.sql  --  SuperAdmin / platform-level procedures.

  These are the ONLY procedures without an @SchoolId first parameter, because
  they operate across tenants. Guard every one of them with
  [Authorize(Roles = "SuperAdmin")] in the API. A school admin must never reach
  them.

  Exception: sp_GetSchoolBranding and sp_GetSchoolBySubdomain are safe to expose
  anonymously -- they return only public branding (name, logo, theme) so the
  React app can style the login page before anyone has signed in.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  sp_CreateSchool -- onboard a tenant, in one transaction.

  A school created without sequences, fee types, settings and an admin is
  unusable: nobody can log in and every registration fails. So this procedure
  does all of it atomically:
      1. the Schools row
      2. the school's first Admin user
      3. SchoolSequences rows (Student / Employee / Receipt)
      4. the seven default FeeTypes (previously a single global list)
      5. the full default Settings set, scoped to this school
      6. a starter Subjects list for grades 1-12 (optional)

  @AdminPasswordHash must be a BCrypt hash produced by the API. If omitted, the
  account gets the shared temporary password (Temp@123) and
  RequirePasswordChange = 1, so it cannot be used without a reset.

  Returns: Result, SchoolId, SchoolCode, AdminUserId, AdminUsername
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateSchool
    @SchoolCode                 NVARCHAR(12),
    @SchoolName                 NVARCHAR(150),
    @Subdomain                  NVARCHAR(63)    = NULL,
    @Address                    NVARCHAR(255)   = NULL,
    @City                       NVARCHAR(80)    = NULL,
    @State                      NVARCHAR(80)    = NULL,
    @Country                    NVARCHAR(80)    = NULL,
    @PostalCode                 NVARCHAR(20)    = NULL,
    @ContactEmail               NVARCHAR(100)   = NULL,
    @ContactPhone               NVARCHAR(20)    = NULL,
    @PrincipalName              NVARCHAR(100)   = NULL,
    @LogoUrl                    NVARCHAR(500)   = NULL,
    @ThemeColor                 NVARCHAR(20)    = '#1976d2',
    @AcademicYearStartMonth     TINYINT         = 4,
    @AdminEmail                 NVARCHAR(100),
    @AdminFirstName             NVARCHAR(50)    = 'School',
    @AdminLastName              NVARCHAR(50)    = 'Admin',
    @AdminPhoneNumber           NVARCHAR(15)    = NULL,
    @AdminPasswordHash          NVARCHAR(255)   = NULL,
    @SeedSubjects               BIT             = 1,
    @CreatedByUserId            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        /* Normalise before validating, so 'dps-noida' becomes 'DPSNOIDA'
           instead of tripping the CHECK constraint. */
        SET @SchoolCode = LEFT(dbo.fn_SanitizeCode(@SchoolCode), 12);
        SET @Subdomain  = NULLIF(LOWER(LTRIM(RTRIM(ISNULL(@Subdomain, N'')))), N'');
        SET @ThemeColor = ISNULL(NULLIF(LTRIM(RTRIM(@ThemeColor)), N''), N'#1976d2');

        IF LEN(@SchoolCode) < 3
        BEGIN
            SELECT 'Error: School code must be at least 3 letters or digits.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        IF NULLIF(LTRIM(RTRIM(ISNULL(@SchoolName, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: School name is required.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        IF NULLIF(LTRIM(RTRIM(ISNULL(@AdminEmail, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Admin email is required.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Schools WHERE SchoolCode = @SchoolCode)
        BEGIN
            SELECT 'Error: School code ''' + @SchoolCode + ''' is already in use.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        IF @Subdomain IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Schools WHERE Subdomain = @Subdomain)
        BEGIN
            SELECT 'Error: Subdomain ''' + @Subdomain + ''' is already in use.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        DECLARE @AdminUsername NVARCHAR(80) = @SchoolCode + N'_ADMIN';

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @AdminUsername)
        BEGIN
            SELECT 'Error: Admin username ''' + @AdminUsername + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
                   CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
            RETURN;
        END

        /* Temp@123 -- only reachable with RequirePasswordChange = 1 below. */
        DECLARE @RequireChange BIT = CASE WHEN @AdminPasswordHash IS NULL THEN 1 ELSE 0 END;
        SET @AdminPasswordHash = ISNULL(@AdminPasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        BEGIN TRANSACTION;

        /*--- 1. the school --------------------------------------------------*/
        INSERT INTO dbo.Schools (SchoolCode, SchoolName, Subdomain, Address, City, State,
                                 Country, PostalCode, ContactEmail, ContactPhone, PrincipalName,
                                 LogoUrl, ThemeColor, AcademicYearStartMonth, IsActive)
        VALUES (@SchoolCode, @SchoolName, @Subdomain, @Address, @City, @State,
                @Country, @PostalCode, @ContactEmail, @ContactPhone, @PrincipalName,
                @LogoUrl, @ThemeColor, @AcademicYearStartMonth, 1);

        DECLARE @SchoolId INT = CAST(SCOPE_IDENTITY() AS INT);

        /*--- 2. the school's first admin ------------------------------------*/
        /* sp_CreateUserAccount writes the Persons row and the Users row together
           and stamps CreatedBy, so the new admin records the SuperAdmin who
           provisioned the school rather than pointing at itself. */
        DECLARE @AdminUserId INT, @AdminPersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @AdminUsername,
            @Email                 = @AdminEmail,
            @PasswordHash          = @AdminPasswordHash,
            @RoleId                = 2,             -- Admin; see Roles seed in 01_Schema.sql
            @FirstName             = @AdminFirstName,
            @LastName              = @AdminLastName,
            @PhoneNumber           = @AdminPhoneNumber,
            @RequirePasswordChange = @RequireChange,
            @ActorUserId           = @CreatedByUserId,
            @UserId                = @AdminUserId OUTPUT,
            @PersonId              = @AdminPersonId OUTPUT;

        /*--- 3. sequences ---------------------------------------------------*/
        INSERT INTO dbo.SchoolSequences (SchoolId, SequenceName, LastValue)
        VALUES (@SchoolId, N'Student', 0),
               (@SchoolId, N'Employee', 0),
               (@SchoolId, N'Receipt', 0);

        /*--- 4. fee types ---------------------------------------------------*/
        INSERT INTO dbo.FeeTypes (SchoolId, FeeTypeName, Description)
        VALUES (@SchoolId, N'Monthly Fee',   N'Regular monthly school fee'),
               (@SchoolId, N'Admission Fee', N'One-time admission fee'),
               (@SchoolId, N'Exam Fee',      N'Examination fee'),
               (@SchoolId, N'Library Fee',   N'Library usage fee'),
               (@SchoolId, N'Lab Fee',       N'Laboratory usage fee'),
               (@SchoolId, N'Transport Fee', N'Transportation fee'),
               (@SchoolId, N'Activity Fee',  N'Extracurricular activity fee');

        /*--- 5. settings ----------------------------------------------------*/
        /* @Silent = 1 matters: without it the seeder's own result set arrives
           first and Dapper's FirstOrDefault() on this procedure would read
           SettingsWritten instead of Result/SchoolId. */
        EXEC dbo.sp_SeedSchoolSettings
            @SchoolId  = @SchoolId,
            @UserId    = @AdminUserId,
            @Overwrite = 0,
            @Silent    = 1;

        /*--- 6. starter subjects --------------------------------------------*/
        IF @SeedSubjects = 1
        BEGIN
            /* Codes carry the grade (ENG01..ENG12) so UQ_Subjects_School_Code
               holds while the same subject exists for several grades. */
            ;WITH Grades AS (
                SELECT CAST(n AS INT) AS G
                FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12)) AS v(n)
            ), Core AS (
                SELECT * FROM (VALUES
                    (N'English',          N'ENG'),
                    (N'Mathematics',      N'MAT'),
                    (N'Science',          N'SCI'),
                    (N'Social Studies',   N'SST'),
                    (N'Hindi',            N'HIN'),
                    (N'Computer Science', N'CSC')
                ) AS v(SubjectName, Prefix)
            )
            INSERT INTO dbo.Subjects (SchoolId, SubjectName, SubjectCode, Grade, IsActive)
            SELECT @SchoolId,
                   c.SubjectName,
                   c.Prefix + RIGHT(N'0' + CAST(g.G AS NVARCHAR(2)), 2),
                   CAST(g.G AS NVARCHAR(10)),
                   1
            FROM Core AS c
            CROSS JOIN Grades AS g;
        END

        EXEC dbo.sp_LogAudit
            @SchoolId   = NULL,
            @UserId     = @CreatedByUserId,
            @Action     = 'School.Create',
            @EntityType = 'School',
            @EntityId   = @SchoolId,
            @Details    = @SchoolCode;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @SchoolId AS SchoolId,
               @SchoolCode AS SchoolCode,
               @AdminUserId AS AdminUserId,
               @AdminUsername AS AdminUsername;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS SchoolId, CAST(NULL AS NVARCHAR(12)) AS SchoolCode,
               CAST(NULL AS INT) AS AdminUserId, CAST(NULL AS NVARCHAR(80)) AS AdminUsername;
    END CATCH
END
GO

/*==============================================================================
  sp_SeedSchoolSettings -- write the default Settings rows for one school.

  Separate from sp_CreateSchool so sp_ResetSettings can reuse it. With
  @Overwrite = 0 it only fills in missing keys, so an upgrade that adds a new
  setting will not wipe a school's customised values.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SeedSchoolSettings
    @SchoolId   INT,
    @UserId     INT = NULL,
    @Overwrite  BIT = 0,
    @Silent     BIT = 0   -- 1 = return no result set (used by sp_CreateSchool)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolName NVARCHAR(150), @SchoolAddress NVARCHAR(255),
            @SchoolPhone NVARCHAR(20), @SchoolEmail NVARCHAR(100),
            @Principal NVARCHAR(100), @StartMonth INT;

    SELECT @SchoolName    = SchoolName,
           @SchoolAddress = ISNULL(Address, N''),
           @SchoolPhone   = ISNULL(ContactPhone, N''),
           @SchoolEmail   = ISNULL(ContactEmail, N''),
           @Principal     = ISNULL(PrincipalName, N''),
           @StartMonth    = AcademicYearStartMonth
    FROM dbo.Schools
    WHERE Id = @SchoolId;

    IF @SchoolName IS NULL
    BEGIN
        IF @Silent = 0 SELECT 'Error: School not found.' AS Result, 0 AS SettingsWritten;
        RETURN;
    END

    /* Derive the academic year labels from the school's own start month rather
       than hardcoding 2024-2025 as the old global seed did. */
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @YearStart INT = dbo.fn_AcademicYear(@SchoolId, @Today);
    DECLARE @AcademicYear NVARCHAR(20) = CAST(@YearStart AS NVARCHAR(4)) + N'-' + CAST(@YearStart + 1 AS NVARCHAR(4));
    DECLARE @YearStartDate NVARCHAR(20) =
        CONVERT(NVARCHAR(10), DATEFROMPARTS(@YearStart, @StartMonth, 1), 23);
    DECLARE @YearEndDate NVARCHAR(20) =
        CONVERT(NVARCHAR(10), DATEADD(DAY, -1, DATEADD(YEAR, 1, DATEFROMPARTS(@YearStart, @StartMonth, 1))), 23);

    DECLARE @Defaults TABLE (
        Category      NVARCHAR(50),
        SettingKey    NVARCHAR(100),
        SettingValue  NVARCHAR(MAX),
        DataType      NVARCHAR(20),
        Description   NVARCHAR(255)
    );

    INSERT INTO @Defaults (Category, SettingKey, SettingValue, DataType, Description) VALUES
    -- System Configuration
    ('SystemConfiguration', 'applicationName',        'School Management System',  'string',  'Application display name'),
    ('SystemConfiguration', 'applicationVersion',     '2.0.0',                     'string',  'Current application version'),
    ('SystemConfiguration', 'maintenanceMode',        'false',                     'boolean', 'Enable maintenance mode'),
    ('SystemConfiguration', 'debugMode',              'false',                     'boolean', 'Enable debug mode'),
    ('SystemConfiguration', 'apiTimeout',             '30',                        'number',  'API timeout in seconds'),
    ('SystemConfiguration', 'tokenExpiration',        '1',                         'number',  'Token expiration in hours'),
    ('SystemConfiguration', 'refreshTokenExpiration', '7',                         'number',  'Refresh token expiration in days'),
    ('SystemConfiguration', 'maxFileSize',            '10',                        'number',  'Maximum file upload size in MB'),
    ('SystemConfiguration', 'allowedFileTypes',       'jpg,jpeg,png,pdf,doc,docx', 'string',  'Allowed file types for upload'),
    -- User Management
    ('UserManagement', 'minPasswordLength',         '8',     'number',  'Minimum password length'),
    ('UserManagement', 'requireUppercase',          'true',  'boolean', 'Require uppercase in password'),
    ('UserManagement', 'requireNumbers',            'true',  'boolean', 'Require numbers in password'),
    ('UserManagement', 'requireSpecialChars',       'true',  'boolean', 'Require special characters in password'),
    ('UserManagement', 'accountLockoutAttempts',    '5',     'number',  'Account lockout after failed attempts'),
    ('UserManagement', 'accountLockoutDuration',    '30',    'number',  'Account lockout duration in minutes'),
    ('UserManagement', 'sessionTimeout',            '60',    'number',  'Session timeout in minutes'),
    ('UserManagement', 'multipleLoginSessions',     'true',  'boolean', 'Allow multiple login sessions'),
    ('UserManagement', 'twoFactorEnabled',          'false', 'boolean', 'Enable two-factor authentication'),
    ('UserManagement', 'emailVerificationRequired', 'true',  'boolean', 'Require email verification'),
    -- Academic Settings
    ('AcademicSettings', 'gradingSystem',        'percentage', 'string',  'Grading system type'),
    ('AcademicSettings', 'passingGrade',         '40',         'number',  'Minimum passing grade'),
    ('AcademicSettings', 'maxGrade',             '100',        'number',  'Maximum grade'),
    ('AcademicSettings', 'attendanceRequired',   '75',         'number',  'Minimum attendance percentage required'),
    ('AcademicSettings', 'maxClassSize',         '50',         'number',  'Maximum students per class'),
    ('AcademicSettings', 'parentPortalEnabled',  'true',       'boolean', 'Enable parent portal access'),
    ('AcademicSettings', 'studentPortalEnabled', 'true',       'boolean', 'Enable student portal access'),
    -- Grading scale, read by fn_CalculateGrade
    ('AcademicSettings', 'gradeThresholdAPlus', '90', 'number', 'Minimum percentage for grade A+'),
    ('AcademicSettings', 'gradeThresholdA',     '80', 'number', 'Minimum percentage for grade A'),
    ('AcademicSettings', 'gradeThresholdB',     '70', 'number', 'Minimum percentage for grade B'),
    ('AcademicSettings', 'gradeThresholdC',     '60', 'number', 'Minimum percentage for grade C'),
    ('AcademicSettings', 'gradeThresholdD',     '50', 'number', 'Minimum percentage for grade D'),
    ('AcademicSettings', 'gradeThresholdE',     '40', 'number', 'Minimum percentage for grade E'),
    -- Security Settings
    ('SecuritySettings', 'enableAuditLog',       'true',  'boolean', 'Enable audit logging'),
    ('SecuritySettings', 'loginAttemptLimit',    '5',     'number',  'Maximum login attempts'),
    ('SecuritySettings', 'ipWhitelistEnabled',   'false', 'boolean', 'Enable IP whitelist'),
    ('SecuritySettings', 'allowedIPs',           '',      'string',  'Comma-separated allowed IP addresses'),
    ('SecuritySettings', 'rateLimitEnabled',     'true',  'boolean', 'Enable API rate limiting'),
    ('SecuritySettings', 'rateLimitRequests',    '100',   'number',  'Rate limit requests per minute'),
    ('SecuritySettings', 'passwordHistoryCount', '5',     'number',  'Number of previous passwords to remember'),
    ('SecuritySettings', 'forcePasswordChange',  '90',    'number',  'Force password change after days'),
    ('SecuritySettings', 'enableBackupSchedule', 'true',  'boolean', 'Enable automatic backup'),
    ('SecuritySettings', 'backupFrequency',      'daily', 'string',  'Backup frequency'),
    -- Notification Settings
    ('NotificationSettings', 'emailNotificationsEnabled',  'true',  'boolean', 'Enable email notifications'),
    ('NotificationSettings', 'smsNotificationsEnabled',    'false', 'boolean', 'Enable SMS notifications'),
    ('NotificationSettings', 'pushNotificationsEnabled',   'true',  'boolean', 'Enable push notifications'),
    ('NotificationSettings', 'slackNotificationsEnabled',  'false', 'boolean', 'Enable Slack notifications'),
    ('NotificationSettings', 'attendanceNotifications',    'true',  'boolean', 'Send attendance notifications'),
    ('NotificationSettings', 'gradeNotifications',         'true',  'boolean', 'Send grade notifications'),
    ('NotificationSettings', 'examNotifications',          'true',  'boolean', 'Send exam notifications'),
    ('NotificationSettings', 'announcementNotifications',  'true',  'boolean', 'Send announcement notifications'),
    ('NotificationSettings', 'feeReminderEnabled',         'true',  'boolean', 'Enable fee reminder notifications'),
    ('NotificationSettings', 'feeReminderDays',            '7',     'number',  'Days before fee due date to send reminder'),
    ('NotificationSettings', 'overdueNotifications',       'true',  'boolean', 'Send overdue fee notifications'),
    ('NotificationSettings', 'paymentConfirmations',       'true',  'boolean', 'Send payment confirmation notifications');

    /* School-specific values, taken from the Schools row instead of the old
       'Sample School' placeholders. */
    INSERT INTO @Defaults (Category, SettingKey, SettingValue, DataType, Description) VALUES
    ('AcademicSettings',   'currentAcademicYear', @AcademicYear,  'string', 'Current academic year'),
    ('AcademicSettings',   'academicYearStart',   @YearStartDate, 'string', 'Academic year start date'),
    ('AcademicSettings',   'academicYearEnd',     @YearEndDate,   'string', 'Academic year end date'),
    ('SystemInformation',  'schoolName',          @SchoolName,    'string', 'School name'),
    ('SystemInformation',  'schoolAddress',       @SchoolAddress, 'string', 'School address'),
    ('SystemInformation',  'schoolPhone',         @SchoolPhone,   'string', 'School phone number'),
    ('SystemInformation',  'schoolEmail',         @SchoolEmail,   'string', 'School email address'),
    ('SystemInformation',  'schoolWebsite',       '',             'string', 'School website URL'),
    ('SystemInformation',  'principalName',       @Principal,     'string', 'Principal name'),
    ('SystemInformation',  'establishedYear',     '',             'string', 'School established year');

    DECLARE @Written INT = 0;

    MERGE dbo.Settings AS tgt
    USING (SELECT @SchoolId AS SchoolId, Category, SettingKey, SettingValue, DataType, Description
           FROM @Defaults) AS src
        ON  tgt.SchoolId = src.SchoolId
        AND tgt.Category = src.Category
        AND tgt.SettingKey = src.SettingKey
    WHEN MATCHED AND @Overwrite = 1 THEN
        UPDATE SET SettingValue = src.SettingValue,
                   DataType     = src.DataType,
                   Description  = src.Description,
                   IsActive     = 1,
                   UpdatedAt    = GETDATE(),
                   UpdatedBy    = @UserId
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (SchoolId, Category, SettingKey, SettingValue, DataType, Description, CreatedBy, UpdatedBy)
        VALUES (src.SchoolId, src.Category, src.SettingKey, src.SettingValue, src.DataType,
                src.Description, @UserId, @UserId);

    SET @Written = @@ROWCOUNT;

    IF @Silent = 0
        SELECT 'Success' AS Result, @Written AS SettingsWritten;
END
GO

/*==============================================================================
  sp_UpdateSchool
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSchool
    @SchoolId                   INT,
    @SchoolName                 NVARCHAR(150)   = NULL,
    @Subdomain                  NVARCHAR(63)    = NULL,
    @Address                    NVARCHAR(255)   = NULL,
    @City                       NVARCHAR(80)    = NULL,
    @State                      NVARCHAR(80)    = NULL,
    @Country                    NVARCHAR(80)    = NULL,
    @PostalCode                 NVARCHAR(20)    = NULL,
    @ContactEmail               NVARCHAR(100)   = NULL,
    @ContactPhone               NVARCHAR(20)    = NULL,
    @PrincipalName              NVARCHAR(100)   = NULL,
    @LogoUrl                    NVARCHAR(500)   = NULL,
    @ThemeColor                 NVARCHAR(20)    = NULL,
    @AcademicYearStartMonth     TINYINT         = NULL,
    @ClearSubdomain             BIT             = 0,
    @UpdatedByUserId            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
        BEGIN
            SELECT 'Error: School not found.' AS Result;
            RETURN;
        END

        SET @Subdomain = NULLIF(LOWER(LTRIM(RTRIM(ISNULL(@Subdomain, N'')))), N'');

        IF @Subdomain IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.Schools WHERE Subdomain = @Subdomain AND Id <> @SchoolId)
        BEGIN
            SELECT 'Error: Subdomain ''' + @Subdomain + ''' is already in use.' AS Result;
            RETURN;
        END

        /* SchoolCode is intentionally not updatable: it is embedded in every
           username and admission number already issued. */
        UPDATE dbo.Schools
           SET SchoolName             = ISNULL(@SchoolName, SchoolName),
               Subdomain              = CASE WHEN @ClearSubdomain = 1 THEN NULL
                                             ELSE ISNULL(@Subdomain, Subdomain) END,
               Address                = ISNULL(@Address, Address),
               City                   = ISNULL(@City, City),
               State                  = ISNULL(@State, State),
               Country                = ISNULL(@Country, Country),
               PostalCode             = ISNULL(@PostalCode, PostalCode),
               ContactEmail           = ISNULL(@ContactEmail, ContactEmail),
               ContactPhone           = ISNULL(@ContactPhone, ContactPhone),
               PrincipalName          = ISNULL(@PrincipalName, PrincipalName),
               LogoUrl                = ISNULL(@LogoUrl, LogoUrl),
               ThemeColor             = ISNULL(@ThemeColor, ThemeColor),
               AcademicYearStartMonth = ISNULL(@AcademicYearStartMonth, AcademicYearStartMonth),
               UpdatedAt              = GETDATE()
         WHERE Id = @SchoolId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedByUserId,
            @Action = 'School.Update', @EntityType = 'School', @EntityId = @SchoolId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_GetSchools -- tenant list with headline counts for the platform dashboard.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchools
    @SearchTerm     NVARCHAR(100) = NULL,
    @IsActive       BIT = NULL,
    @PageNumber     INT = 1,
    @PageSize       INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 50) BETWEEN 1 AND 500 THEN @PageSize ELSE 50 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');

    SELECT s.Id,
           s.SchoolCode,
           s.SchoolName,
           s.Subdomain,
           s.Address,
           s.City,
           s.State,
           s.Country,
           s.PostalCode,
           s.ContactEmail,
           s.ContactPhone,
           s.PrincipalName,
           s.LogoUrl,
           s.ThemeColor,
           s.AcademicYearStartMonth,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           ISNULL(cnt.TotalStudents, 0) AS TotalStudents,
           ISNULL(cnt.TotalTeachers, 0) AS TotalTeachers,
           ISNULL(cnt.TotalClasses,  0) AS TotalClasses,
           ISNULL(cnt.TotalUsers,    0) AS TotalUsers,
           COUNT(*) OVER () AS TotalCount
    FROM dbo.Schools AS s
    OUTER APPLY (
        SELECT (SELECT COUNT(*) FROM dbo.Students AS st WHERE st.SchoolId = s.Id AND st.IsActive = 1) AS TotalStudents,
               (SELECT COUNT(*) FROM dbo.Teachers AS te WHERE te.SchoolId = s.Id AND te.IsActive = 1) AS TotalTeachers,
               (SELECT COUNT(*) FROM dbo.Classes  AS cl WHERE cl.SchoolId = s.Id AND cl.IsActive = 1) AS TotalClasses,
               (SELECT COUNT(*) FROM dbo.Users    AS us WHERE us.SchoolId = s.Id AND us.IsActive = 1) AS TotalUsers
    ) AS cnt
    WHERE (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@SearchTerm IS NULL
           OR s.SchoolName LIKE '%' + @SearchTerm + '%'
           OR s.SchoolCode LIKE '%' + @SearchTerm + '%'
           OR s.City       LIKE '%' + @SearchTerm + '%')
    ORDER BY s.SchoolName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

/*==============================================================================
  sp_GetSchoolById
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolById
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SchoolCode, SchoolName, Subdomain, Address, City, State, Country,
           PostalCode, ContactEmail, ContactPhone, PrincipalName, LogoUrl, ThemeColor,
           AcademicYearStartMonth, IsActive, CreatedAt, UpdatedAt
    FROM dbo.Schools
    WHERE Id = @SchoolId;
END
GO

/*==============================================================================
  sp_GetSchoolByCode
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolByCode
    @SchoolCode NVARCHAR(12)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SchoolCode, SchoolName, Subdomain, Address, City, State, Country,
           PostalCode, ContactEmail, ContactPhone, PrincipalName, LogoUrl, ThemeColor,
           AcademicYearStartMonth, IsActive, CreatedAt, UpdatedAt
    FROM dbo.Schools
    WHERE SchoolCode = dbo.fn_SanitizeCode(@SchoolCode);
END
GO

/*==============================================================================
  sp_GetSchoolBySubdomain -- resolve a wildcard host to a tenant.

  For the *.yourdomain.com deployment: the API reads the Host header, passes the
  leading label here, and uses the result to brand the login page. Only public
  fields, so this may be called anonymously.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolBySubdomain
    @Subdomain NVARCHAR(63)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id AS SchoolId,
           SchoolCode,
           SchoolName,
           Subdomain,
           LogoUrl,
           ThemeColor,
           IsActive
    FROM dbo.Schools
    WHERE Subdomain = LOWER(LTRIM(RTRIM(@Subdomain)));
END
GO

/*==============================================================================
  sp_GetSchoolBranding -- public branding only. Safe for anonymous callers.

  Deliberately excludes contact details, counts and anything else a competitor
  or scraper should not be able to enumerate.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolBranding
    @SchoolId   INT = NULL,
    @SchoolCode NVARCHAR(12) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id AS SchoolId,
           SchoolCode,
           SchoolName,
           LogoUrl,
           ThemeColor,
           IsActive
    FROM dbo.Schools
    WHERE (@SchoolId IS NOT NULL AND Id = @SchoolId)
       OR (@SchoolId IS NULL AND @SchoolCode IS NOT NULL
           AND SchoolCode = dbo.fn_SanitizeCode(@SchoolCode));
END
GO

/*==============================================================================
  sp_ToggleSchoolStatus -- suspend or restore a tenant.

  Deactivating a school also revokes its users' refresh tokens; otherwise a
  suspended school's staff would stay signed in until their tokens expired.
  sp_Login already refuses users whose school is inactive.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ToggleSchoolStatus
    @SchoolId           INT,
    @IsActive           BIT,
    @UpdatedByUserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
        BEGIN
            SELECT 'Error: School not found.' AS Result, CAST(NULL AS BIT) AS IsActive;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Schools
           SET IsActive = @IsActive,
               UpdatedAt = GETDATE()
         WHERE Id = @SchoolId;

        IF @IsActive = 0
        BEGIN
            UPDATE rt
               SET rt.IsActive = 0,
                   rt.RevokedAt = GETUTCDATE()
            FROM dbo.RefreshTokens AS rt
            INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
            WHERE u.SchoolId = @SchoolId
              AND rt.IsActive = 1;
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedByUserId,
            @Action = 'School.ToggleStatus', @EntityType = 'School', @EntityId = @SchoolId,
            @Details = NULL;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @IsActive AS IsActive;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS BIT) AS IsActive;
    END CATCH
END
GO

/*==============================================================================
  sp_CreateSchoolAdmin -- add a further Admin to an existing school.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateSchoolAdmin
    @SchoolId       INT,
    @Email          NVARCHAR(100),
    @PasswordHash   NVARCHAR(255),
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Username       NVARCHAR(80) = NULL,
    @CreatedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        /* Auto-name as CODE_ADMIN2, _ADMIN3, ... so the first admin keeps the
           plain CODE_ADMIN username. */
        IF NULLIF(LTRIM(RTRIM(ISNULL(@Username, N''))), N'') IS NULL
        BEGIN
            DECLARE @n INT = 2;
            SET @Username = @Code + N'_ADMIN2';
            WHILE EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username) AND @n < 100
            BEGIN
                SET @n = @n + 1;
                SET @Username = @Code + N'_ADMIN' + CAST(@n AS NVARCHAR(3));
            END
        END
        ELSE
        BEGIN
            /* An explicit username still has to carry the school prefix, or a
               later school could not create the same name. */
            SET @Username = dbo.fn_SanitizeCode(@Username);
            IF @Username NOT LIKE @Code + N'[_]%' SET @Username = @Code + N'_' + @Username;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            SELECT 'Error: Username ''' + @Username + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: A user with this email already exists in this school.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId     = @SchoolId,
            @Username     = @Username,
            @Email        = @Email,
            @PasswordHash = @PasswordHash,
            @RoleId       = 2,              -- Admin; see Roles seed in 01_Schema.sql
            @FirstName    = @FirstName,
            @LastName     = @LastName,
            @PhoneNumber  = @PhoneNumber,
            @ActorUserId  = @CreatedByUserId,
            @UserId       = @UserId OUTPUT,
            @PersonId     = @PersonId OUTPUT;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @CreatedByUserId,
            @Action = 'Admin.Create', @EntityType = 'User', @EntityId = @UserId,
            @Details = @Username;

        SELECT 'Success' AS Result, @UserId AS UserId, @Username AS Username;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
    END CATCH
END
GO

/*==============================================================================
  sp_GetPlatformStats -- totals across all tenants, for the SuperAdmin home.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetPlatformStats
AS
BEGIN
    SET NOCOUNT ON;

    SELECT (SELECT COUNT(*) FROM dbo.Schools)                              AS TotalSchools,
           (SELECT COUNT(*) FROM dbo.Schools WHERE IsActive = 1)           AS ActiveSchools,
           (SELECT COUNT(*) FROM dbo.Schools WHERE IsActive = 0)           AS InactiveSchools,
           /* RoleId literals rather than a join: 1..5 are fixed by the Roles seed
              in 01_Schema.sql and named the same way by Constants.RoleIds in C#. */
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 4 AND IsActive = 1) AS TotalStudents,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 3 AND IsActive = 1) AS TotalTeachers,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 5 AND IsActive = 1) AS TotalParents,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 2 AND IsActive = 1) AS TotalAdmins,
           (SELECT COUNT(*) FROM dbo.Classes  WHERE IsActive = 1)          AS TotalClasses,
           (SELECT COUNT(*) FROM dbo.Schools WHERE CreatedAt >= DATEADD(DAY, -30, GETDATE())) AS SchoolsAddedLast30Days;
END
GO

/*==============================================================================
  sp_GetSchoolUsageReport -- per-school activity, for billing or capacity work.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolUsageReport
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ToDate   = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, @ToDate));

    SELECT s.Id AS SchoolId,
           s.SchoolCode,
           s.SchoolName,
           s.IsActive,
           (SELECT COUNT(*) FROM dbo.Students   AS x WHERE x.SchoolId = s.Id AND x.IsActive = 1) AS ActiveStudents,
           (SELECT COUNT(*) FROM dbo.Teachers   AS x WHERE x.SchoolId = s.Id AND x.IsActive = 1) AS ActiveTeachers,
           (SELECT COUNT(*) FROM dbo.Attendance AS x WHERE x.SchoolId = s.Id AND x.AttendanceDate BETWEEN @FromDate AND @ToDate) AS AttendanceRecords,
           (SELECT COUNT(*) FROM dbo.Results    AS x WHERE x.SchoolId = s.Id AND CAST(x.CreatedAt AS DATE) BETWEEN @FromDate AND @ToDate) AS ResultsEntered,
           (SELECT ISNULL(SUM(x.AmountPaid), 0) FROM dbo.FeePayments AS x
             WHERE x.SchoolId = s.Id AND x.PaymentStatus = 'Completed'
               AND x.PaymentDate BETWEEN @FromDate AND @ToDate) AS FeesCollected,
           (SELECT MAX(u.LastLoginAt) FROM dbo.Users AS u WHERE u.SchoolId = s.Id) AS LastLoginAt
    FROM dbo.Schools AS s
    ORDER BY s.SchoolName;
END
GO

/*==============================================================================
  SECTION -- ROLES AND ROLE PERMISSIONS

  Roles are global (no SchoolId), so they live in this file with the other
  tenant-free objects. Ids 1..5 are the system roles seeded by 01_Schema.sql and
  cannot be renamed or deleted; anything a school adds gets Id >= 100.
==============================================================================*/

/*==============================================================================
  sp_GetRoles -- the role list, with how many users hold each one.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRoles
    @IncludeInactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id,
           r.RoleName,
           r.RoleCode,
           r.Description,
           r.IsSystemRole,
           r.IsActive,
           (SELECT COUNT(*) FROM dbo.Users AS u WHERE u.RoleId = r.Id)                  AS UserCount,
           /* Modules the role can actually see. CanView rather than "has a row":
              a row with all four flags off grants nothing, and the grid editor
              writes such rows when a module is switched off (PHASE 14). */
           (SELECT COUNT(*) FROM dbo.RolePermissions AS p WHERE p.RoleId = r.Id
                                                            AND p.IsActive = 1
                                                            AND p.CanView = 1)          AS ModuleCount,
           r.CreatedBy,
           cb.Username AS CreatedByUsername,
           r.ModifiedBy,
           mb.Username AS ModifiedByUsername,
           r.CreatedAt,
           r.UpdatedAt
    FROM dbo.Roles AS r
    LEFT JOIN dbo.Users AS cb ON cb.Id = r.CreatedBy
    LEFT JOIN dbo.Users AS mb ON mb.Id = r.ModifiedBy
    WHERE (@IncludeInactive = 1 OR r.IsActive = 1)
    ORDER BY r.Id;
END
GO

/*==============================================================================
  sp_GetRoleById -- one role plus its permission grid, as two result sets.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRoleById
    @RoleId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id,
           r.RoleName,
           r.RoleCode,
           r.Description,
           r.IsSystemRole,
           r.IsActive,
           (SELECT COUNT(*) FROM dbo.Users AS u WHERE u.RoleId = r.Id) AS UserCount,
           (SELECT COUNT(*) FROM dbo.RolePermissions AS p WHERE p.RoleId = r.Id
                                                            AND p.IsActive = 1
                                                            AND p.CanView = 1) AS ModuleCount,
           r.CreatedBy,
           cb.Username AS CreatedByUsername,
           r.ModifiedBy,
           mb.Username AS ModifiedByUsername,
           r.CreatedAt,
           r.UpdatedAt
    FROM dbo.Roles AS r
    LEFT JOIN dbo.Users AS cb ON cb.Id = r.CreatedBy
    LEFT JOIN dbo.Users AS mb ON mb.Id = r.ModifiedBy
    WHERE r.Id = @RoleId;

    EXEC dbo.sp_GetRolePermissions @RoleId = @RoleId;
END
GO

/*==============================================================================
  sp_GetRolePermissions -- the CanView/CanCreate/CanEdit/CanDelete grid.

  A module with no row is absent from the result, which the API reads as "no
  access". Nothing is invented here so an empty grid stays visibly empty.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRolePermissions
    @RoleId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.RoleId,
           r.RoleName,
           p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete,
           p.IsActive,
           p.CreatedBy,
           p.ModifiedBy,
           p.CreatedAt,
           p.UpdatedAt
    FROM dbo.RolePermissions AS p
    INNER JOIN dbo.Roles AS r ON r.Id = p.RoleId
    WHERE (@RoleId IS NULL OR p.RoleId = @RoleId)
    ORDER BY p.RoleId, p.ModuleName;
END
GO

/*==============================================================================
  sp_GetUserPermissions -- the effective grid for one user, for the JWT.

  Called on login and on refresh, so the token carries the permissions and the
  per-request authorisation check needs no database round trip.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserPermissions
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.Users AS u
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = u.RoleId
    WHERE u.Id = @UserId
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

/*==============================================================================
  sp_CreateRole -- add a custom role.

  Ids >= 100 by CK_Roles_Id: the 1..5 band is reserved for the system roles that
  CK_Users_SchoolScope and Constants.RoleIds refer to by number. Because the
  column is not IDENTITY, the next id is computed here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateRole
    @RoleName       NVARCHAR(50),
    @RoleCode       NVARCHAR(20)    = NULL,
    @Description    NVARCHAR(255)   = NULL,
    @CreatedBy      INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        SET @RoleName = NULLIF(LTRIM(RTRIM(ISNULL(@RoleName, N''))), N'');
        SET @RoleCode = NULLIF(LTRIM(RTRIM(ISNULL(@RoleCode, N''))), N'');
        SET @RoleCode = ISNULL(@RoleCode, LEFT(dbo.fn_SanitizeCode(@RoleName), 20));

        IF @RoleName IS NULL
        BEGIN
            SELECT 'Error: Role name is required.' AS Result, CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        /* PHASE 14: a name with no letters or digits ("---") sanitises to an
           empty code, which the first such role would take and every later one
           would collide with under a confusing message. */
        IF @RoleCode = N''
        BEGIN
            SELECT 'Error: A role code could not be derived from that name. Supply one.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = @RoleName)
        BEGIN
            SELECT 'Error: Role ''' + @RoleName + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleCode = @RoleCode)
        BEGIN
            SELECT 'Error: Role code ''' + @RoleCode + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* HOLDLOCK on the MAX makes two concurrent creates queue rather than
           both pick the same id. */
        DECLARE @RoleId INT =
            (SELECT ISNULL(MAX(Id), 99) + 1 FROM dbo.Roles WITH (UPDLOCK, HOLDLOCK) WHERE Id >= 100);

        INSERT INTO dbo.Roles (Id, RoleName, RoleCode, Description, IsSystemRole,
                               IsActive, CreatedBy, ModifiedBy)
        VALUES (@RoleId, @RoleName, @RoleCode, @Description, 0, 1, @CreatedBy, @CreatedBy);

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @CreatedBy,
            @Action = 'Role.Create', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @RoleName;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @RoleId AS RoleId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS RoleId;
    END CATCH
END
GO

/*==============================================================================
  sp_UpdateRole -- rename or deactivate a role.

  A system role may have its description edited but not its name, code or active
  flag: the application refers to those by value, and CK_Users_SchoolScope
  depends on role 1 continuing to exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateRole
    @RoleId         INT,
    @RoleName       NVARCHAR(50)    = NULL,
    @Description    NVARCHAR(255)   = NULL,
    @IsActive       BIT             = NULL,
    @ModifiedBy     INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @IsSystemRole BIT, @CurrentName NVARCHAR(50);
        SELECT @IsSystemRole = IsSystemRole, @CurrentName = RoleName
        FROM dbo.Roles WHERE Id = @RoleId;

        IF @IsSystemRole IS NULL
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        SET @RoleName = NULLIF(LTRIM(RTRIM(ISNULL(@RoleName, N''))), N'');

        /* PHASE 14: RoleUpdateDTO always carries the name, so resending the
           current one is "no rename", not a rename. Before this, every update
           of a system role -- description included -- was refused. The
           comparison is case-sensitive: recasing "admin" is still a rename. */
        IF @RoleName COLLATE Latin1_General_BIN = @CurrentName COLLATE Latin1_General_BIN
            SET @RoleName = NULL;

        IF @IsSystemRole = 1 AND (@RoleName IS NOT NULL OR @IsActive = 0)
        BEGIN
            SELECT 'Error: A system role cannot be renamed or deactivated.' AS Result;
            RETURN;
        END

        IF @RoleName IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = @RoleName AND Id <> @RoleId)
        BEGIN
            SELECT 'Error: Role ''' + @RoleName + ''' already exists.' AS Result;
            RETURN;
        END

        /* Deactivating a role would leave its holders unable to log in, so block
           it while anyone still has it. */
        IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Users WHERE RoleId = @RoleId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Active users still hold this role. Reassign them first.' AS Result;
            RETURN;
        END

        UPDATE dbo.Roles
           SET RoleName    = ISNULL(@RoleName, RoleName),
               /* NULL keeps the description; a blank string clears it. */
               Description = CASE WHEN @Description IS NULL THEN Description
                                  ELSE NULLIF(LTRIM(RTRIM(@Description)), N'') END,
               IsActive    = ISNULL(@IsActive, IsActive),
               ModifiedBy  = ISNULL(@ModifiedBy, ModifiedBy),
               UpdatedAt   = GETDATE()
         WHERE Id = @RoleId;

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @ModifiedBy,
            @Action = 'Role.Update', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @CurrentName;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteRole -- remove a custom role and its permission rows.

  A hard delete, because a role nobody holds carries no history worth keeping and
  FK_Users_Role guarantees nothing points at it. System roles are never deletable.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteRole
    @RoleId     INT,
    @DeletedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @IsSystemRole BIT, @RoleName NVARCHAR(50);
        SELECT @IsSystemRole = IsSystemRole, @RoleName = RoleName
        FROM dbo.Roles WHERE Id = @RoleId;

        IF @IsSystemRole IS NULL
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        IF @IsSystemRole = 1
        BEGIN
            SELECT 'Error: A system role cannot be deleted.' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE RoleId = @RoleId)
        BEGIN
            SELECT 'Error: Users still hold this role. Reassign them first.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        DELETE FROM dbo.RolePermissions WHERE RoleId = @RoleId;
        DELETE FROM dbo.Roles           WHERE Id = @RoleId;

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @DeletedBy,
            @Action = 'Role.Delete', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @RoleName;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_SaveRolePermission -- set one (role, module) cell of the grid.

  Insert-or-update on (RoleId, ModuleName), matching UQ_RolePermissions_Role_Module,
  so the API can send the whole grid one row at a time and stay idempotent.

  CanView is forced on when any of create/edit/delete is granted: editing
  something you cannot see is not a state the UI can represent, and
  CK_RolePermissions_ViewImplied would reject it anyway.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SaveRolePermission
    @RoleId         INT,
    @ModuleName     NVARCHAR(50),
    @CanView        BIT = 0,
    @CanCreate      BIT = 0,
    @CanEdit        BIT = 0,
    @CanDelete      BIT = 0,
    @IsActive       BIT = 1,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @ModuleName = NULLIF(LTRIM(RTRIM(ISNULL(@ModuleName, N''))), N'');

        IF @ModuleName IS NULL
        BEGIN
            SELECT 'Error: Module name is required.' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Id = @RoleId)
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        /* PHASE 14: the SuperAdmin's grid is not consulted -- the permission
           handler short-circuits role 1 -- but the UI builds its menus from
           it, so an edit here could only hide screens the server still
           serves. */
        IF @RoleId = 1
        BEGIN
            SELECT 'Error: The SuperAdmin role always has every permission; its grid cannot be changed.' AS Result;
            RETURN;
        END

        IF @CanCreate = 1 OR @CanEdit = 1 OR @CanDelete = 1 SET @CanView = 1;

        IF EXISTS (SELECT 1 FROM dbo.RolePermissions
                    WHERE RoleId = @RoleId AND ModuleName = @ModuleName)
        BEGIN
            UPDATE dbo.RolePermissions
               SET CanView    = @CanView,
                   CanCreate  = @CanCreate,
                   CanEdit    = @CanEdit,
                   CanDelete  = @CanDelete,
                   IsActive   = @IsActive,
                   ModifiedBy = ISNULL(@ModifiedBy, ModifiedBy),
                   UpdatedAt  = GETDATE()
             WHERE RoleId = @RoleId AND ModuleName = @ModuleName;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.RolePermissions (RoleId, ModuleName, CanView, CanCreate, CanEdit,
                                             CanDelete, IsActive, CreatedBy, ModifiedBy)
            VALUES (@RoleId, @ModuleName, @CanView, @CanCreate, @CanEdit,
                    @CanDelete, @IsActive, @ModifiedBy, @ModifiedBy);
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @ModifiedBy,
            @Action = 'Role.Permission', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @ModuleName;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteRolePermission -- revoke a module from a role outright.

  Removes the row rather than clearing the four flags, so the grid distinguishes
  "explicitly nothing" from "never configured". Both deny; only one shows intent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteRolePermission
    @RoleId     INT,
    @ModuleName NVARCHAR(50),
    @DeletedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* PHASE 14: the SuperAdmin's grid is not consulted -- the permission
           handler short-circuits role 1 -- but the UI builds its menus from
           it, so an edit here could only hide screens the server still
           serves. */
        IF @RoleId = 1
        BEGIN
            SELECT 'Error: The SuperAdmin role always has every permission; its grid cannot be changed.' AS Result;
            RETURN;
        END

        DELETE FROM dbo.RolePermissions
        WHERE RoleId = @RoleId AND ModuleName = @ModuleName;

        IF @@ROWCOUNT = 0
        BEGIN
            SELECT 'Error: No permission row for that role and module.' AS Result;
            RETURN;
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @DeletedBy,
            @Action = 'Role.PermissionRevoke', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @ModuleName;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

PRINT '=== 03_Procs_Platform.sql complete ===';
GO

SET NOEXEC OFF;
GO
