/*==============================================================================
  StoredProcedure : dbo.sp_GetDailyAttendanceReport
  Extracted from: 09_Procs_Attendance.sql
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
  sp_GetDailyAttendanceReport -- NEW. One row per date for a class.

  Returns: AttendanceDate, PresentCount, AbsentCount, TotalMarked,
           AttendancePercentage
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetDailyAttendanceReport
    @SchoolId   INT,
    @ClassId    INT = NULL,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT a.AttendanceDate,
           SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END) AS PresentCount,
           SUM(CASE WHEN a.IsPresent = 0 THEN 1 ELSE 0 END) AS AbsentCount,
           COUNT(*) AS TotalMarked,
           CAST(ROUND(100.0 * SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END)
                      / NULLIF(COUNT(*), 0), 2) AS DECIMAL(5,2)) AS AttendancePercentage
    FROM dbo.Attendance AS a
    WHERE a.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR a.ClassId = @ClassId)
      AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    GROUP BY a.AttendanceDate
    ORDER BY a.AttendanceDate DESC;
END
GO

SET NOEXEC OFF;
GO
