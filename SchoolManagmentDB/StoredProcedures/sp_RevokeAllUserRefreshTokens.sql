/*==============================================================================
  StoredProcedure : dbo.sp_RevokeAllUserRefreshTokens
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
  sp_RevokeAllUserRefreshTokens -- Returns: Result, TokensRevoked
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RevokeAllUserRefreshTokens
    @UserId     INT,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        DECLARE @Revoked INT = @@ROWCOUNT;

        SELECT 'Success' AS Result, @Revoked AS TokensRevoked;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS TokensRevoked;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
