/*==============================================================================
  StoredProcedure : dbo.sp_Login
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
  sp_Login

  Returns:
      Id, Username, Email, PasswordHash, FirstName, LastName, PhoneNumber,
      Address, RoleId, Role, RoleCode, IsActive, RequirePasswordChange,
      RoleIdentifier, SchoolId, SchoolCode, SchoolName

  PasswordHash IS RETURNED ON PURPOSE. BCrypt.Verify runs in C#
  (AuthService.LoginAsync), so the hash has to travel back with the row. It is
  never put into a DTO or a claim -- AuthRepository reads it, verifies, drops it.

  RoleId is now the INT foreign key to dbo.Roles. The human-facing identifier
  (admission number / employee id) that this column used to carry is returned as
  RoleIdentifier -- a rename, and the one breaking change in this refactor.

  Reads dbo.vw_Users, which re-joins Users + Persons + Roles + primary Address,
  so the flat column list survived the table split.

  Returns NO ROWS when the user is inactive or their school is suspended, so
  the API's existing "user == null -> invalid credentials" path covers both.
  If you want to tell a suspended school apart from a wrong password, look the
  school up separately -- do not relax this filter.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_Login
    @Username NVARCHAR(80),
    @Password NVARCHAR(255) = NULL   -- accepted for compatibility; verified in C#
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.Username,
           u.Email,
           u.PasswordHash,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           /* The human-facing identifier for the role: a student's admission
              number or a teacher's employee id. */
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS st
           ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te
           ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools AS sc
           ON sc.Id = u.SchoolId
    WHERE u.Username = @Username
      AND u.IsActive = 1
      /* SuperAdmin (RoleId 1) has no school; everyone else needs an active one. */
      AND (u.RoleId = 1 OR sc.IsActive = 1);

    /* Second result set: the permission grid for the JWT. Sent with the login row
       so minting a token is one round trip. AuthRepository reads both.

       The eligibility filter is repeated verbatim from the SELECT above. A refused
       login must return NEITHER set: handing back a permission grid for a
       suspended school would tell the caller the account exists, and would leave
       AuthRepository holding claims for a user it is about to reject. */
    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.Users AS us
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = us.RoleId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = us.SchoolId
    WHERE us.Username = @Username
      AND us.IsActive = 1
      AND (us.RoleId = 1 OR sc.IsActive = 1)
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

SET NOEXEC OFF;
GO
