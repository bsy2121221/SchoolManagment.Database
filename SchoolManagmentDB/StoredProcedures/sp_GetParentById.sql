/*==============================================================================
  StoredProcedure : dbo.sp_GetParentById
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
  sp_GetParentById -- one parent, same shape as the list row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentById
    @SchoolId   INT,
    @ParentId   INT
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
           CAST(NULL AS NVARCHAR(20)) AS Relationship,
           kids.ChildrenNames,
           ISNULL(kids.ChildrenCount, 0) AS ChildrenCount
    FROM dbo.Parents AS p
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
    OUTER APPLY (
        SELECT STRING_AGG(cu.FirstName + N' ' + cu.LastName, N', ') AS ChildrenNames,
               COUNT(*) AS ChildrenCount
        FROM dbo.StudentParents AS sp
        INNER JOIN dbo.Students  AS s  ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
        INNER JOIN dbo.vw_Users  AS cu ON cu.SchoolId = s.SchoolId AND cu.Id = s.UserId
        WHERE sp.SchoolId = p.SchoolId
          AND sp.ParentId = p.Id
          AND sp.IsActive = 1
          AND s.IsActive = 1
    ) AS kids
    WHERE p.SchoolId = @SchoolId
      AND p.Id = @ParentId;

    /* No IsActive filter on purpose: a deactivated parent must still be readable,
       or the admin who deactivated them cannot see what they did. */
END
GO

SET NOEXEC OFF;
GO
