/*==============================================================================
  StoredProcedure : dbo.sp_GetChildrenByParent
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
  sp_GetChildrenByParent -- the children of one parent, keyed on Parents.Id.

  sp_GetStudentChildren in 06_Procs_Students.sql answers the same question from
  the parent's Users.Id, which is what the parent portal has. This one takes
  Parents.Id, which is what an administrator looking at a parent record has, and
  is why both exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetChildrenByParent
    @SchoolId   INT,
    @ParentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           u.FirstName,
           u.LastName,
           u.Email,
           ISNULL(c.ClassName, N'') AS ClassName,
           ISNULL(c.Grade,     N'') AS Grade,
           ISNULL(c.Section,   N'') AS Section,
           sp.Relationship
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Students AS s ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId  AND u.Id = s.UserId
    LEFT  JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE sp.SchoolId = @SchoolId
      AND sp.ParentId = @ParentId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
