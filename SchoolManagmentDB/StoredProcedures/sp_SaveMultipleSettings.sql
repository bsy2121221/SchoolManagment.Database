/*==============================================================================
  StoredProcedure : dbo.sp_SaveMultipleSettings
  Extracted from: 13_Procs_Settings.sql
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

SET NOEXEC OFF;
GO
