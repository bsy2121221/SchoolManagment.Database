/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherScheduleByDay
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
  sp_GetTeacherScheduleByDay
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherScheduleByDay
    @SchoolId   INT,
    @TeacherId  INT,
    @DayOfWeek  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
           ts.IsActive,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.DayOfWeek = @DayOfWeek
      AND ts.IsActive = 1
    ORDER BY ts.StartTime;
END
GO

SET NOEXEC OFF;
GO
