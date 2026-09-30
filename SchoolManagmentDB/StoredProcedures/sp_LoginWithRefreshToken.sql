/*==============================================================================
  StoredProcedure : dbo.sp_LoginWithRefreshToken
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
  sp_LoginWithRefreshToken -- one round trip: validate a token and return the
  user detail needed to mint a new JWT.

  Returns no rows if the token is unusable, so the API treats it exactly like a
  failed login.

  Two result sets, matching sp_Login: the user row, then the permission grid. The
  refreshed access token has to carry the same claims as the original, permissions
  included -- and re-reading them here is what makes a permission change take
  effect at the next refresh rather than at the next full login.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LoginWithRefreshToken
    @Token NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.vw_Users AS u ON u.Id = rt.UserId
    LEFT JOIN dbo.Students AS st ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools  AS sc ON sc.Id = u.SchoolId
    WHERE rt.Token = @Token
      AND rt.IsActive = 1
      AND rt.RevokedAt IS NULL
      AND rt.ExpiryDate > GETUTCDATE()
      AND u.IsActive = 1
      AND (u.RoleId = 1 OR sc.IsActive = 1);

    /* Same eligibility filter as above, for the same reason: an unusable token
       must yield no permission grid either. */
    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS us ON us.Id = rt.UserId
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = us.RoleId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = us.SchoolId
    WHERE rt.Token = @Token
      AND rt.IsActive = 1
      AND rt.RevokedAt IS NULL
      AND rt.ExpiryDate > GETUTCDATE()
      AND us.IsActive = 1
      AND (us.RoleId = 1 OR sc.IsActive = 1)
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

SET NOEXEC OFF;
GO
