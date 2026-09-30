/*==============================================================================
  StoredProcedure : dbo.sp_DeleteSetting
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

SET NOEXEC OFF;
GO
