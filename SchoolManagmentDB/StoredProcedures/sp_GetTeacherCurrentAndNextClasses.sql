/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherCurrentAndNextClasses
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
  sp_GetTeacherCurrentAndNextClasses

  Returns TWO result sets, as before: the current lesson, then the next one.
  Read with QueryMultiple.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherCurrentAndNextClasses
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    /* 1900-01-01 was a Monday, so this yields 1 = Monday .. 7 = Sunday whatever
       DATEFIRST happens to be on the connection. */
    DECLARE @CurrentDay  INT  = (DATEDIFF(DAY, '19000101', CAST(GETDATE() AS DATE)) % 7) + 1;
    DECLARE @CurrentTime TIME = CAST(GETDATE() AS TIME);

    SELECT TOP 1
           'Current' AS ClassType,
           ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
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
      AND ts.DayOfWeek = @CurrentDay
      AND ts.StartTime <= @CurrentTime
      AND ts.EndTime > @CurrentTime
      AND ts.IsActive = 1
    ORDER BY ts.StartTime;

    /* DayOffset wraps: 0 = later today, 1..6 = a following day, 7 = this same
       weekday next week. Sunday evening therefore rolls forward to Monday
       instead of returning nothing. */
    SELECT TOP 1
           'Next' AS ClassType,
           ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
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
      AND ts.IsActive = 1
    ORDER BY CASE
               WHEN ts.DayOfWeek = @CurrentDay AND ts.StartTime > @CurrentTime THEN 0
               WHEN ts.DayOfWeek = @CurrentDay THEN 7
               ELSE (ts.DayOfWeek - @CurrentDay + 7) % 7
             END,
             ts.StartTime;
END
GO

SET NOEXEC OFF;
GO
