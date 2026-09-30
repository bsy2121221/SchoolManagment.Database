/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherByUserId
  Extracted from: 02_Functions.sql
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
  sp_GetTeacherByUserId -- translate a logged-in Users.Id to a Teachers.Id.

  BREAKING CHANGE HELPER: TeacherSchedule.TeacherId and
  TeacherSubjectAssignments.TeacherId used to hold Users.Id while
  TeacherSubjects.TeacherId held Teachers.Id, so joins between them were wrong.
  All three now hold Teachers.Id, and every procedure taking @TeacherId means
  Teachers.Id. The API resolves it once with this procedure.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherByUserId
    @SchoolId INT,
    @UserId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id AS TeacherId,
           t.UserId,
           t.EmployeeId,
           u.FirstName,
           u.LastName,
           t.IsActive
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = t.SchoolId
           AND u.Id = t.UserId
    WHERE t.SchoolId = @SchoolId
      AND t.UserId = @UserId;
END
GO

/*==============================================================================
  SECTION -- IDENTITY HELPERS (Roles / Persons / Addresses)

  Added with the Users -> Users + Persons + Addresses split. Every procedure that
  writes a person goes through sp_UpsertPerson / sp_UpsertAddress rather than
  touching the tables directly, so the audit columns and the tenant checks are
  applied in exactly one place.
==============================================================================*/

/*==============================================================================
  fn_RoleId -- role name OR role code -> Roles.Id. NULL if no such role.

  Accepts either spelling so a caller can pass the JWT's 'Teacher' or the
  database's 'TEACHER' without knowing which it holds.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_RoleId (@Role NVARCHAR(50))
RETURNS INT
AS
BEGIN
    SET @Role = NULLIF(LTRIM(RTRIM(ISNULL(@Role, N''))), N'');
    IF @Role IS NULL RETURN NULL;

    RETURN (SELECT TOP (1) Id
            FROM dbo.Roles
            WHERE IsActive = 1
              AND (RoleName = @Role OR RoleCode = @Role)
            ORDER BY Id);
END
GO

/*==============================================================================
  fn_RoleName -- Roles.Id -> name, for messages and audit details.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_RoleName (@RoleId INT)
RETURNS NVARCHAR(50)
AS
BEGIN
    RETURN (SELECT RoleName FROM dbo.Roles WHERE Id = @RoleId);
END
GO

SET NOEXEC OFF;
GO
