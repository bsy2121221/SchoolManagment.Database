/*==============================================================================
  StoredProcedure : dbo.sp_GetAttendanceSummary
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
  sp_GetAttendanceSummary -- NEW. Per-student percentages over a date range.

  Returns: StudentId, StudentNumber, RollNumber, FirstName, LastName,
           ClassId, ClassName, Grade, Section,
           PresentDays, AbsentDays, TotalDays, AttendancePercentage
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAttendanceSummary
    @SchoolId   INT,
    @ClassId    INT = NULL,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END) AS PresentDays,
           SUM(CASE WHEN a.IsPresent = 0 THEN 1 ELSE 0 END) AS AbsentDays,
           COUNT(a.Id) AS TotalDays,
           /* NULLIF avoids divide-by-zero for a student with nothing marked;
              the column comes back NULL rather than failing the whole report. */
           CAST(ROUND(100.0 * SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END)
                      / NULLIF(COUNT(a.Id), 0), 2) AS DECIMAL(5,2)) AS AttendancePercentage
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN dbo.Attendance AS a
           ON a.SchoolId = s.SchoolId
          AND a.StudentId = s.Id
          AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND s.IsActive = 1
      AND u.IsActive = 1
    GROUP BY s.Id, s.StudentId, s.RollNumber, u.FirstName, u.LastName,
             c.Id, c.ClassName, c.Grade, c.Section
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section,
             TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
