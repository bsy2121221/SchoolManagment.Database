/*==============================================================================
  StoredProcedure : dbo.sp_GetUserById
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
  sp_GetUserById

  Also returns PasswordHash: AuthService.ChangePasswordAsync has to verify the
  current password in C# before it can store a new one.

  @SchoolId is optional and confines the lookup to one school. UserRepository
  already passed it -- and this procedure only declared @UserId, so every call
  from GET /api/users/{id} failed outright with "too many arguments specified".
  It is a real filter rather than an ignored parameter because CanAccessUser
  checks that the caller is an admin, not which school they administer: without
  this, one school's admin could read another school's user by guessing an id.
  AuthService reads a user by id alone (it has only the token), so NULL means
  no school filter.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserById
    @UserId   INT,
    @SchoolId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
           u.PasswordHash,
           u.FirstName,
           u.LastName,
           u.FullName,
           u.PhoneNumber,
           u.AlternatePhoneNumber,
           u.Address,
           u.AddressId,
           u.AddressType,
           u.AddressLine1,
           u.AddressLine2,
           u.Landmark,
           u.City,
           u.State,
           u.Country,
           u.PostalCode,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS st ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools  AS sc ON sc.Id = u.SchoolId
    WHERE u.Id = @UserId
      AND (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
END
GO

SET NOEXEC OFF;
GO
