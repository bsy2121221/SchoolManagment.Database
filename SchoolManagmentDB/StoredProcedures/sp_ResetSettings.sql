/*==============================================================================
  StoredProcedure : dbo.sp_ResetSettings
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

SET NOEXEC OFF;
GO
