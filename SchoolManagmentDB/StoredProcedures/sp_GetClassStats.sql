/*==============================================================================
  StoredProcedure : dbo.sp_GetClassStats
  Extracted from: 08_Procs_Classes.sql
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
  sp_GetClassStats

  Column names kept: TotalStudents, MaxStudents, PresentLast30Days,
  AbsentLast30Days, TotalExaminations, TotalFees, OverdueFees
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassStats
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Since DATE = CAST(DATEADD(DAY, -30, GETDATE()) AS DATE);
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) AS TotalStudents,

           (SELECT MaxStudents FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND Id = @ClassId) AS MaxStudents,

           (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1
               AND Gender = 'Male') AS MaleStudents,

           (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1
               AND Gender = 'Female') AS FemaleStudents,

           /* Of the marks actually taken in the window, not of the roll. NULL when
              the register has not been opened at all, because 0% there would read
              as a class that never attends. Two decimals: ClassStatsDTO carries
              this as a decimal, and rounding at the source keeps the API from
              reporting 87.333333333333. */
           (SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                        ELSE ROUND(SUM(CASE WHEN a.IsPresent = 1 THEN 1.0 ELSE 0 END)
                                   * 100.0 / COUNT(*), 2)
                   END
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since) AS AverageAttendance,

           (SELECT COUNT(*)
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since AND a.IsPresent = 1) AS PresentLast30Days,

           (SELECT COUNT(*)
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since AND a.IsPresent = 0) AS AbsentLast30Days,

           (SELECT COUNT(*) FROM dbo.Examinations
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) AS TotalExaminations,

           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              INNER JOIN dbo.Students AS s ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
             WHERE f.SchoolId = @SchoolId AND s.ClassId = @ClassId AND f.IsActive = 1) AS TotalFees,

           /* Past due and not yet covered by completed payments. */
           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              INNER JOIN dbo.Students AS s ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND f.IsActive = 1
               AND f.DueDate < @Today
               AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees;
END
GO

SET NOEXEC OFF;
GO
