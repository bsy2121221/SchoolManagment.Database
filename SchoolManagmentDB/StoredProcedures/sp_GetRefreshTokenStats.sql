/*==============================================================================
  StoredProcedure : dbo.sp_GetRefreshTokenStats
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
  sp_GetRefreshTokenStats
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRefreshTokenStats
    @SchoolId INT = NULL   -- NULL = whole platform (SuperAdmin only)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS TotalTokens,
           SUM(CASE WHEN rt.IsActive = 1 AND rt.ExpiryDate > GETUTCDATE() THEN 1 ELSE 0 END) AS ActiveTokens,
           SUM(CASE WHEN rt.ExpiryDate <= GETUTCDATE() THEN 1 ELSE 0 END) AS ExpiredTokens,
           SUM(CASE WHEN rt.RevokedAt IS NOT NULL THEN 1 ELSE 0 END) AS RevokedTokens,
           COUNT(DISTINCT rt.UserId) AS DistinctUsers
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
    WHERE (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
END
GO

SET NOEXEC OFF;
GO
