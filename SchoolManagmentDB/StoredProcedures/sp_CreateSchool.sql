/*==============================================================================
  StoredProcedure : dbo.sp_CreateSchool
  Extracted from: 03_Procs_Platform.sql
  Part of SchoolManagementDB structured layout.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    PRINT '*** Select the School Management database first (USE <db> / sqlcmd -d <db>). ***';
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

SET NOEXEC OFF;
GO
