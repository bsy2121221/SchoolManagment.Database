/*==============================================================================
  StoredProcedure : dbo.sp_GetParentsByStudent
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
  sp_GetParentsByStudent -- who to contact about one student.

  Same row shape as sp_GetAllParents, with Relationship filled in: this is the one
  call where it means something, because it is a property of the link rather than
  of the parent.

  The old query smuggled sp.Relationship out through the ChildrenNames column, so
  a caller reading ParentDTO.ChildrenNames got 'Father' where it expected a list
  of children. Both fields are populated properly here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentsByStudent
    @SchoolId   INT,
    @StudentId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.SchoolId,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           sp.Relationship,
           kids.ChildrenNames,
           ISNULL(kids.ChildrenCount, 0) AS ChildrenCount
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Parents  AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = p.SchoolId  AND u.Id = p.UserId
    OUTER APPLY (
        SELECT STRING_AGG(cu.FirstName + N' ' + cu.LastName, N', ') AS ChildrenNames,
               COUNT(*) AS ChildrenCount
        FROM dbo.StudentParents AS sp2
        INNER JOIN dbo.Students AS s2  ON s2.SchoolId = sp2.SchoolId AND s2.Id = sp2.StudentId
        INNER JOIN dbo.vw_Users AS cu  ON cu.SchoolId = s2.SchoolId  AND cu.Id = s2.UserId
        WHERE sp2.SchoolId = p.SchoolId
          AND sp2.ParentId = p.Id
          AND sp2.IsActive = 1
          AND s2.IsActive = 1
    ) AS kids
    WHERE sp.SchoolId = @SchoolId
      AND sp.StudentId = @StudentId
      AND sp.IsActive = 1
      AND p.IsActive = 1
    ORDER BY sp.Relationship, u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
