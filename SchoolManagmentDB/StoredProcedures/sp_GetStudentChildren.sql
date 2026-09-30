/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentChildren
  Extracted from: 06_Procs_Students.sql
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
  sp_GetStudentChildren -- the students linked to a parent (parent portal).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentChildren
    @SchoolId       INT,
    @ParentUserId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.BloodGroup,
           s.AdmissionDate,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           sp.Relationship
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Parents  AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
    INNER JOIN dbo.Students AS s ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId  AND u.Id = s.UserId
    LEFT JOIN  dbo.Classes  AS c ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE sp.SchoolId = @SchoolId
      AND p.UserId = @ParentUserId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
