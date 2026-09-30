/*==============================================================================
  StoredProcedure : dbo.sp_SeedSchoolSettings
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

SET NOEXEC OFF;
GO
