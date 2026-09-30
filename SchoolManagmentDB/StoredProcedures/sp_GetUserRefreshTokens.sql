/*==============================================================================
  StoredProcedure : dbo.sp_GetUserRefreshTokens
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
  sp_GetUserRefreshTokens -- session list for a user (admin/debug view).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserRefreshTokens
    @UserId         INT,
    @IncludeRevoked BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT rt.Id,
           rt.UserId,
           rt.Token,
           rt.ExpiryDate,
           rt.IsActive,
           rt.CreatedAt,
           rt.RevokedAt,
           rt.RevokedByIp,
           rt.ReplacedByToken,
           CAST(CASE WHEN rt.ExpiryDate <= GETUTCDATE() THEN 1 ELSE 0 END AS BIT) AS IsExpired
    FROM dbo.RefreshTokens AS rt
    WHERE rt.UserId = @UserId
      AND (@IncludeRevoked = 1 OR rt.IsActive = 1)
    ORDER BY rt.CreatedAt DESC;
END
GO

SET NOEXEC OFF;
GO
