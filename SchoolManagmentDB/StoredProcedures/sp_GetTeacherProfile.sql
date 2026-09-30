/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherProfile
  Extracted from: 07_Procs_Teachers.sql
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
  sp_GetTeacherProfile

  AssignedClasses now matches c.ClassTeacherId against t.Id, not u.Id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherProfile
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           t.Salary,
           t.JoinDate,
           t.IsActive,

           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           u.CreatedAt,
           u.UpdatedAt,

           (SELECT STRING_AGG(sub.SubjectName, ', ')
              FROM dbo.TeacherSubjects AS ts
              INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ts.SchoolId AND sub.Id = ts.SubjectId
             WHERE ts.SchoolId = t.SchoolId AND ts.TeacherId = t.Id AND ts.IsActive = 1) AS AssignedSubjects,

           (SELECT STRING_AGG(CONCAT(c.Grade, c.Section, ' (', c.ClassName, ')'), ', ')
              FROM dbo.Classes AS c
             WHERE c.SchoolId = t.SchoolId AND c.ClassTeacherId = t.Id AND c.IsActive = 1) AS AssignedClasses,

           t.SchoolId,
           sch.SchoolCode,
           sch.SchoolName
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Schools AS sch ON sch.Id = t.SchoolId
    WHERE t.SchoolId = @SchoolId
      AND t.UserId = @UserId
      AND t.IsActive = 1;
END
GO

SET NOEXEC OFF;
GO
