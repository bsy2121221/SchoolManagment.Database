/*==============================================================================
  StoredProcedure : dbo.sp_ValidateRefreshToken
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
  sp_ValidateRefreshToken -- Returns: IsValid, UserId

  A token is valid only if it is active, unrevoked, unexpired (UTC), owned by an
  active user, AND that user's school is still active. The school check is what
  logs out a suspended school on its next refresh.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ValidateRefreshToken
    @Token NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(CASE
               WHEN rt.Id IS NOT NULL
                AND rt.IsActive = 1
                AND rt.RevokedAt IS NULL
                AND rt.ExpiryDate > GETUTCDATE()
                AND u.IsActive = 1
                AND (u.RoleId = 1 OR sc.IsActive = 1)
               THEN 1 ELSE 0
           END AS BIT) AS IsValid,
           rt.UserId
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = u.SchoolId
    WHERE rt.Token = @Token;
END
GO

SET NOEXEC OFF;
GO
