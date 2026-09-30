/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentAttendance
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
  sp_GetStudentAttendance
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentAttendance
    @SchoolId   INT,
    @StudentId  INT,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT a.Id,
           a.AttendanceDate,
           a.IsPresent,
           a.Remarks,
           a.MarkedAt,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.Attendance AS a
    INNER JOIN dbo.Classes AS c ON c.SchoolId = a.SchoolId AND c.Id = a.ClassId
    WHERE a.SchoolId = @SchoolId
      AND a.StudentId = @StudentId
      AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    ORDER BY a.AttendanceDate DESC;
END
GO

SET NOEXEC OFF;
GO
