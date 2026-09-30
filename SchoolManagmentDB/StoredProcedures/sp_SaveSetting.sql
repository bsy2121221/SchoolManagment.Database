/*==============================================================================
  StoredProcedure : dbo.sp_SaveSetting
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

SET NOEXEC OFF;
GO
