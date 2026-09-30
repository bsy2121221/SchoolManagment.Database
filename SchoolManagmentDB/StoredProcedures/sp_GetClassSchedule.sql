/*==============================================================================
  StoredProcedure : dbo.sp_GetClassSchedule
  Extracted from: 12_Procs_Schedule.sql
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
  sp_GetClassSchedule -- the timetable from the class's side.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassSchedule
    @SchoolId   INT,
    @ClassId    INT,
    @DayOfWeek  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ts.Id,
           ts.DayOfWeek,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           ts.StartTime,
           ts.EndTime,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted,
           ts.Room,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           t.Id AS TeacherId,
           t.EmployeeId,
           CONCAT(u.FirstName, ' ', u.LastName) AS TeacherName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    INNER JOIN dbo.Teachers AS t ON t.SchoolId = ts.SchoolId AND t.Id = ts.TeacherId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId  AND u.Id = t.UserId
    WHERE ts.SchoolId = @SchoolId
      AND ts.ClassId = @ClassId
      AND (@DayOfWeek IS NULL OR ts.DayOfWeek = @DayOfWeek)
      AND ts.IsActive = 1
    ORDER BY ts.DayOfWeek, ts.StartTime;
END
GO

SET NOEXEC OFF;
GO
