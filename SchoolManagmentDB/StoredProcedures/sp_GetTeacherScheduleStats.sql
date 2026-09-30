/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherScheduleStats
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
  sp_GetTeacherScheduleStats

  Column names kept: TotalClasses, TotalSubjects, TotalClassesAssigned,
  DaysInWeek, EarliestClass, LatestClass, TotalMinutesPerWeek
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherScheduleStats
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS TotalClasses,
           COUNT(DISTINCT SubjectId) AS TotalSubjects,
           COUNT(DISTINCT ClassId) AS TotalClassesAssigned,
           COUNT(DISTINCT DayOfWeek) AS DaysInWeek,
           MIN(StartTime) AS EarliestClass,
           MAX(EndTime) AS LatestClass,
           ISNULL(SUM(DATEDIFF(MINUTE, StartTime, EndTime)), 0) AS TotalMinutesPerWeek
    FROM dbo.TeacherSchedule
    WHERE SchoolId = @SchoolId
      AND TeacherId = @TeacherId
      AND IsActive = 1;
END
GO

SET NOEXEC OFF;
GO
