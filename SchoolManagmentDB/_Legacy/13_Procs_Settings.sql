/*==============================================================================
  13_Procs_Settings.sql  --  Per-school settings.

  Settings used to be global: one row per (Category, SettingKey) for the whole
  installation. The 'SystemInformation' category alone held schoolName,
  schoolAddress, schoolPhone, principalName -- so two schools would have
  overwritten each other's identity. The key is now
  (SchoolId, Category, SettingKey) and every procedure takes @SchoolId.

  FIXES
    * sp_ResetSettings was advertised as "reset to default" but its body was
      UPDATE Settings SET IsActive = 0 -- with no WHERE at all when @Category was
      NULL. It deactivated every setting of every school and restored no
      defaults, leaving the settings page empty and fn_CalculateGrade with no
      grade thresholds. It now deletes the rows in scope and re-seeds that
      school's defaults through sp_SeedSchoolSettings.
    * sp_SaveSetting's UPDATE branch left IsActive alone, so a setting that had
      been deleted could never be brought back -- saving it reported 'Updated'
      while every read proc still filtered it out. Save now sets IsActive = 1.
    * sp_SaveMultipleSettings had ROLLBACK TRANSACTION in its CATCH with no
      XACT_STATE() check. A failure that had already aborted the transaction hit
      error 3903 ("ROLLBACK TRANSACTION request has no corresponding BEGIN") and
      the caller got that instead of the real message.
    * sp_SaveMultipleSettings parsed the same JSON three times (insert filter,
      insert select, update join) and would fail outright on a payload
      containing the same key twice. One MERGE over a de-duplicated set now.
    * Neither save proc validated DataType or the value against it. 'number'
      settings could hold 'abc'; fn_CalculateGrade reads gradeThresholdAPlus and
      friends as numbers, so one bad save silently broke grading for the school.
      Both are validated up front with a readable message instead of a CHECK
      constraint violation.
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
  sp_GetAllSettings
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSettings
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id,
           Category,
           SettingKey,
           SettingValue,
           DataType,
           Description,
           IsActive,
           CreatedAt,
           UpdatedAt,
           CreatedBy,
           UpdatedBy,
           SchoolId
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY Category, SettingKey;
END
GO

/*==============================================================================
  sp_GetSettingsByCategory
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSettingsByCategory
    @SchoolId   INT,
    @Category   NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id,
           Category,
           SettingKey,
           SettingValue,
           DataType,
           Description,
           IsActive,
           CreatedAt,
           UpdatedAt,
           CreatedBy,
           UpdatedBy,
           SchoolId
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND Category = @Category
      AND IsActive = 1
    ORDER BY SettingKey;
END
GO

/*==============================================================================
  sp_GetSettingByKey -- returns no row when the key does not exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSettingByKey
    @SchoolId   INT,
    @Category   NVARCHAR(50),
    @SettingKey NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id,
           Category,
           SettingKey,
           SettingValue,
           DataType,
           Description,
           IsActive,
           CreatedAt,
           UpdatedAt,
           CreatedBy,
           UpdatedBy,
           SchoolId
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND Category = @Category
      AND SettingKey = @SettingKey
      AND IsActive = 1;
END
GO

/*==============================================================================
  fn_IsValidSettingValue -- does @Value make sense for @DataType?

  Used by both save procs so a 'number' setting cannot end up holding text.
  Returns 1 for valid, 0 for invalid. An unknown @DataType returns 0.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_IsValidSettingValue
(
    @DataType NVARCHAR(20),
    @Value    NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    IF @Value IS NULL RETURN 0;

    RETURN CASE
             WHEN @DataType = 'string'  THEN 1
             WHEN @DataType = 'number'  THEN CASE WHEN TRY_CONVERT(DECIMAL(38, 10), @Value) IS NULL
                                                  THEN 0 ELSE 1 END
             /* The React settings page posts JS booleans, the seed data uses
                'true'/'false', and some older rows hold '1'/'0'. All accepted. */
             WHEN @DataType = 'boolean' THEN CASE WHEN LOWER(@Value) IN ('true', 'false', '1', '0')
                                                  THEN 1 ELSE 0 END
             WHEN @DataType = 'json'    THEN CASE WHEN ISJSON(@Value) = 1 THEN 1 ELSE 0 END
             ELSE 0
           END;
END
GO

/*==============================================================================
  sp_SaveSetting

  Returns: Result ('Created' / 'Updated' / 'Error'), Message
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SaveSetting
    @SchoolId       INT,
    @Category       NVARCHAR(50),
    @SettingKey     NVARCHAR(100),
    @SettingValue   NVARCHAR(MAX),
    @DataType       NVARCHAR(20) = 'string',
    @Description    NVARCHAR(255) = NULL,
    @UserId         INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF @DataType NOT IN ('string', 'number', 'boolean', 'json')
        BEGIN
            SELECT 'Error' AS Result,
                   'DataType must be string, number, boolean or json' AS Message;
            RETURN;
        END

        IF dbo.fn_IsValidSettingValue(@DataType, @SettingValue) = 0
        BEGIN
            SELECT 'Error' AS Result,
                   'Value is not a valid ' + @DataType AS Message;
            RETURN;
        END

        /* @UserId is stamped into CreatedBy/UpdatedBy, which are composite FKs on
           (SchoolId, Id). A SuperAdmin editing a school's settings has
           SchoolId NULL and would fail that FK, so store NULL rather than
           blowing up mid-save. */
        DECLARE @Stamp INT = CASE
                               WHEN EXISTS (SELECT 1 FROM dbo.Users
                                             WHERE SchoolId = @SchoolId AND Id = @UserId)
                               THEN @UserId
                             END;

        IF EXISTS (SELECT 1 FROM dbo.Settings
                    WHERE SchoolId = @SchoolId AND Category = @Category
                      AND SettingKey = @SettingKey)
        BEGIN
            UPDATE dbo.Settings
               SET SettingValue = @SettingValue,
                   DataType     = @DataType,
                   Description  = @Description,
                   IsActive     = 1,   -- revive a previously deleted setting
                   UpdatedAt    = GETDATE(),
                   UpdatedBy    = @Stamp
             WHERE SchoolId = @SchoolId
               AND Category = @Category
               AND SettingKey = @SettingKey;

            SELECT 'Updated' AS Result, 'Setting updated successfully' AS Message;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.Settings (SchoolId, Category, SettingKey, SettingValue,
                                      DataType, Description, CreatedBy, UpdatedBy)
            VALUES (@SchoolId, @Category, @SettingKey, @SettingValue,
                    @DataType, @Description, @Stamp, @Stamp);

            SELECT 'Created' AS Result, 'Setting created successfully' AS Message;
        END
    END TRY
    BEGIN CATCH
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message;
    END CATCH
END
GO

/*==============================================================================
  sp_SaveMultipleSettings -- one MERGE, one transaction.

  @SettingsJson:
      [{"category":"AcademicSettings","settingKey":"passingGrade",
        "settingValue":"35","dataType":"number","description":"..."}, ...]

  A payload listing the same (category, settingKey) twice keeps the LAST
  occurrence -- MERGE cannot touch the same target row twice and would otherwise
  abort the whole batch.

  Rows with an invalid DataType or a value that does not match it are skipped
  and counted rather than failing the save, so one bad field on the settings page
  does not discard the other thirty.

  Returns: Result, Message, SettingsSaved, SettingsSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SaveMultipleSettings
    @SchoolId       INT,
    @UserId         INT,
    @SettingsJson   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF ISJSON(ISNULL(@SettingsJson, N'')) <> 1
        BEGIN
            SELECT 'Error' AS Result, 'SettingsJson is not valid JSON' AS Message,
                   0 AS SettingsSaved, 0 AS SettingsSkipped;
            RETURN;
        END

        EXEC dbo.sp_AssertSchool @SchoolId;

        DECLARE @Stamp INT = CASE
                               WHEN EXISTS (SELECT 1 FROM dbo.Users
                                             WHERE SchoolId = @SchoolId AND Id = @UserId)
                               THEN @UserId
                             END;

        DECLARE @In TABLE
        (
            Ordinal      INT,
            Category     NVARCHAR(50),
            SettingKey   NVARCHAR(100),
            SettingValue NVARCHAR(MAX),
            DataType     NVARCHAR(20),
            Description  NVARCHAR(255)
        );

        INSERT INTO @In (Ordinal, Category, SettingKey, SettingValue, DataType, Description)
        SELECT CAST(j.[key] AS INT),
               v.Category,
               v.SettingKey,
               v.SettingValue,
               ISNULL(NULLIF(v.DataType, N''), N'string'),
               v.Description
        FROM OPENJSON(@SettingsJson) AS j
        CROSS APPLY OPENJSON(j.value)
             WITH (Category     NVARCHAR(50)  '$.category',
                   SettingKey   NVARCHAR(100) '$.settingKey',
                   SettingValue NVARCHAR(MAX) '$.settingValue',
                   DataType     NVARCHAR(20)  '$.dataType',
                   Description  NVARCHAR(255) '$.description') AS v
        WHERE v.Category IS NOT NULL
          AND v.SettingKey IS NOT NULL;

        DECLARE @Requested INT = (SELECT COUNT(*) FROM @In);

        DECLARE @Valid TABLE
        (
            Category     NVARCHAR(50),
            SettingKey   NVARCHAR(100),
            SettingValue NVARCHAR(MAX),
            DataType     NVARCHAR(20),
            Description  NVARCHAR(255),
            PRIMARY KEY (Category, SettingKey)
        );

        INSERT INTO @Valid (Category, SettingKey, SettingValue, DataType, Description)
        SELECT d.Category, d.SettingKey, d.SettingValue, d.DataType, d.Description
        FROM (SELECT i.*,
                     ROW_NUMBER() OVER (PARTITION BY i.Category, i.SettingKey
                                        ORDER BY i.Ordinal DESC) AS rn
              FROM @In AS i
              WHERE i.DataType IN ('string', 'number', 'boolean', 'json')
                AND dbo.fn_IsValidSettingValue(i.DataType, i.SettingValue) = 1) AS d
        WHERE d.rn = 1;

        BEGIN TRANSACTION;

        MERGE dbo.Settings AS tgt
        USING (SELECT @SchoolId AS SchoolId, Category, SettingKey, SettingValue,
                      DataType, Description
                 FROM @Valid) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.Category = src.Category
            AND tgt.SettingKey = src.SettingKey
        WHEN MATCHED THEN
            UPDATE SET SettingValue = src.SettingValue,
                       DataType     = src.DataType,
                       Description  = src.Description,
                       IsActive     = 1,
                       UpdatedAt    = GETDATE(),
                       UpdatedBy    = @Stamp
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, Category, SettingKey, SettingValue,
                    DataType, Description, CreatedBy, UpdatedBy)
            VALUES (src.SchoolId, src.Category, src.SettingKey, src.SettingValue,
                    src.DataType, src.Description, @Stamp, @Stamp);

        DECLARE @Saved INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               'Settings saved successfully' AS Message,
               @Saved AS SettingsSaved,
               @Requested - @Saved AS SettingsSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message,
               0 AS SettingsSaved, 0 AS SettingsSkipped;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteSetting -- soft delete, scoped to the school.

  Returns: Result ('Success' / 'NotFound' / 'Error'), Message
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteSetting
    @SchoolId   INT,
    @Category   NVARCHAR(50),
    @SettingKey NVARCHAR(100),
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @Stamp INT = CASE
                               WHEN EXISTS (SELECT 1 FROM dbo.Users
                                             WHERE SchoolId = @SchoolId AND Id = @UserId)
                               THEN @UserId
                             END;

        UPDATE dbo.Settings
           SET IsActive  = 0,
               UpdatedAt = GETDATE(),
               UpdatedBy = @Stamp
         WHERE SchoolId = @SchoolId
           AND Category = @Category
           AND SettingKey = @SettingKey
           AND IsActive = 1;

        IF @@ROWCOUNT > 0
            SELECT 'Success' AS Result, 'Setting deleted successfully' AS Message;
        ELSE
            SELECT 'NotFound' AS Result, 'Setting not found' AS Message;
    END TRY
    BEGIN CATCH
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message;
    END CATCH
END
GO

/*==============================================================================
  sp_ResetSettings -- restore this school's defaults.

  @Category NULL resets every category for the school; otherwise only that one.

  The rows in scope are hard-deleted and then re-seeded by
  sp_SeedSchoolSettings, which is the single definition of what a default is
  (03_Procs_Platform.sql). Deleting rather than deactivating matters: the unique
  key (SchoolId, Category, SettingKey) ignores IsActive, so a soft-deleted row
  would still be MATCHED by the seed MERGE and stay switched off.

  Seeding runs with @Overwrite = 0 so that resetting one category cannot quietly
  revert the other categories the user has customised.

  Returns: Result, Message, SettingsRestored
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ResetSettings
    @SchoolId   INT,
    @Category   NVARCHAR(50) = NULL,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        /* Guard against a typo'd category wiping rows and restoring nothing. */
        IF @Category IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Settings
                            WHERE SchoolId = @SchoolId AND Category = @Category)
        BEGIN
            SELECT 'NotFound' AS Result,
                   'No settings exist in category ' + @Category AS Message,
                   0 AS SettingsRestored;
            RETURN;
        END

        BEGIN TRANSACTION;

        DELETE FROM dbo.Settings
         WHERE SchoolId = @SchoolId
           AND (@Category IS NULL OR Category = @Category);

        EXEC dbo.sp_SeedSchoolSettings @SchoolId  = @SchoolId,
                                       @UserId    = @UserId,
                                       @Overwrite = 0,
                                       @Silent    = 1;

        DECLARE @Restored INT = (SELECT COUNT(*) FROM dbo.Settings
                                  WHERE SchoolId = @SchoolId
                                    AND (@Category IS NULL OR Category = @Category));

        COMMIT TRANSACTION;

        EXEC dbo.sp_LogAudit @SchoolId   = @SchoolId,
                             @UserId     = @UserId,
                             @Action     = N'ResetSettings',
                             @EntityType = N'Settings',
                             @EntityId   = NULL,
                             @Details    = @Category;

        SELECT 'Success' AS Result,
               'Settings reset successfully' AS Message,
               @Restored AS SettingsRestored;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message, 0 AS SettingsRestored;
    END CATCH
END
GO

PRINT '=== 13_Procs_Settings.sql complete ===';
GO

SET NOEXEC OFF;
GO
