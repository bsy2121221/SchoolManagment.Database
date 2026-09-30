/*==============================================================================
  StoredProcedure : dbo.sp_GetRefreshToken
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
  sp_GetRefreshToken -- token plus enough user detail to mint a new JWT.

  SchoolId / SchoolCode / SchoolName are essential here, not decorative: the
  refresh path issues a fresh access token, and if it omitted the school claims
  the refreshed token would have no tenant and every subsequent request would
  fail closed.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRefreshToken
    @Token NVARCHAR(255)
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
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           /* Aliased: rt.IsActive is already in this result set, and two columns
              of the same name make Dapper's mapping order-dependent. */
           u.IsActive AS UserIsActive,
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
    WHERE rt.Token = @Token;
END
GO

SET NOEXEC OFF;
GO
