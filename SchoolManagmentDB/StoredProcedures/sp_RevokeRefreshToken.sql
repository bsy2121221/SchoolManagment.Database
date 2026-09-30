/*==============================================================================
  StoredProcedure : dbo.sp_RevokeRefreshToken
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
  sp_RevokeRefreshToken
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RevokeRefreshToken
    @Token              NVARCHAR(255),
    @IpAddress          NVARCHAR(50) = NULL,
    @ReplacedByToken    NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.RefreshTokens WHERE Token = @Token)
        BEGIN
            SELECT 'Error: Refresh token not found.' AS Result;
            RETURN;
        END

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress,
               ReplacedByToken = @ReplacedByToken
         WHERE Token = @Token
           AND IsActive = 1;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
