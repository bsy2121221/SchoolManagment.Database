/*==============================================================================
  StoredProcedure : dbo.sp_GetParentProfile
  Extracted from: 17_Procs_Parents.sql
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
  sp_GetParentProfile -- the parent's own screen, keyed on dbo.Users.Id.

  TWO result sets, because ParentProfileDTO carries a Children list:
    1. the parent, their login, and their school
    2. one row per linked child (the sp_GetChildrenByParent shape)

  Keyed on @UserId rather than @ParentId because GET /api/Parents/my-profile has
  only the token's UserId to work with.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentProfile
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           p.SchoolId,
           sch.SchoolCode,
           sch.SchoolName
    FROM dbo.Parents AS p
    INNER JOIN dbo.vw_Users AS u   ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
    INNER JOIN dbo.Schools  AS sch ON sch.Id = p.SchoolId
    WHERE p.SchoolId = @SchoolId
      AND p.UserId = @UserId;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           cu.FirstName,
           cu.LastName,
           cu.Email,
           /* ParentChildDTO declares these three non-nullable, and a student
              between classes has none, so the empty string is the honest answer
              rather than a null landing in a string property. */
           ISNULL(c.ClassName, N'') AS ClassName,
           ISNULL(c.Grade,     N'') AS Grade,
           ISNULL(c.Section,   N'') AS Section,
           sp.Relationship
    FROM dbo.Parents AS p
    INNER JOIN dbo.StudentParents AS sp ON sp.SchoolId = p.SchoolId AND sp.ParentId = p.Id
    INNER JOIN dbo.Students       AS s  ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users       AS cu ON cu.SchoolId = s.SchoolId AND cu.Id = s.UserId
    LEFT  JOIN dbo.Classes        AS c  ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE p.SchoolId = @SchoolId
      AND p.UserId = @UserId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY cu.FirstName, cu.LastName;
END
GO

SET NOEXEC OFF;
GO
