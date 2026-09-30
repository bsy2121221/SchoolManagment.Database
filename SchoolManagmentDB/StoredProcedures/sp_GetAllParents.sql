/*==============================================================================
  StoredProcedure : dbo.sp_GetAllParents
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
  sp_GetAllParents -- the school's parents, with their children summarised.

  @IncludeInactive = 1 returns deactivated parents too. sp_GetTeachersWithDetails
  hard-filters IsActive = 1, which is why a soft-deleted teacher is unreachable
  through the API; this takes the flag so the same hole is not dug twice.

  Returns one row per parent. ChildrenNames is comma-joined for display only --
  callers that need the children as rows use sp_GetChildrenByParent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllParents
    @SchoolId        INT,
    @IncludeInactive BIT = 0
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
           /* Relationship is per link, so it is meaningless on a whole-school
              list. sp_GetParentsByStudent is the call that fills it. */
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
      AND (@IncludeInactive = 1 OR p.IsActive = 1)
    ORDER BY u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
