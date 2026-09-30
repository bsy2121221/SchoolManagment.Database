/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherProfileStats
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
  sp_GetTeacherProfileStats

  Every count used to compare Classes.ClassTeacherId against @UserId. Since that
  column holds Teachers.Id, all five numbers were wrong (usually zero, or
  another teacher's figures when the ids happened to coincide). They now compare
  against the resolved Teachers.Id.

  Column names kept: ClassesAssigned, StudentsUnderCare, SubjectsAssigned,
  AttendanceMarkedLastMonth, ResultsEnteredLastMonth
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherProfileStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                               WHERE SchoolId = @SchoolId AND UserId = @UserId);

    DECLARE @Since DATE = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);

    SELECT (SELECT COUNT(*) FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1) AS ClassesAssigned,

           (SELECT COUNT(DISTINCT s.Id)
              FROM dbo.Classes AS c
              INNER JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id
             WHERE c.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
               AND c.IsActive = 1 AND s.IsActive = 1) AS StudentsUnderCare,

           (SELECT COUNT(*) FROM dbo.TeacherSubjects
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1) AS SubjectsAssigned,

           /* Attendance is credited to whoever marked it (MarkedBy is a
              Users.Id), which is more accurate than the old "any attendance in a
              class I happen to own". */
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND MarkedBy = @UserId
               AND AttendanceDate >= @Since) AS AttendanceMarkedLastMonth,

           (SELECT COUNT(*)
              FROM dbo.Results AS r
              INNER JOIN dbo.Students AS s ON s.SchoolId = r.SchoolId AND s.Id = r.StudentId
              INNER JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
             WHERE r.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
               AND r.CreatedAt >= @Since) AS ResultsEnteredLastMonth;
END
GO

SET NOEXEC OFF;
GO
