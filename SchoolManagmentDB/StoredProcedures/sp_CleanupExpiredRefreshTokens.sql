/*==============================================================================
  StoredProcedure : dbo.sp_CleanupExpiredRefreshTokens
  Extracted from: 04_Procs_Auth.sql
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
  sp_CleanupExpiredRefreshTokens -- housekeeping.
  Returns: Result, TokensDeleted
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CleanupExpiredRefreshTokens
    @RetainRevokedDays INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DELETE FROM dbo.RefreshTokens
         WHERE ExpiryDate < DATEADD(DAY, -ABS(ISNULL(@RetainRevokedDays, 30)), GETUTCDATE());

        DECLARE @Deleted INT = @@ROWCOUNT;

        SELECT 'Success' AS Result, @Deleted AS TokensDeleted;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS TokensDeleted;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
