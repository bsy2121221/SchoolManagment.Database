/*==============================================================================
  StoredProcedure : dbo.sp_GetDashboardStats
  Extracted from: 14_Procs_Dashboard.sql
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
  sp_GetDashboardStats

  Column names kept: TotalStudents, TotalTeachers, TotalParents, TotalClasses,
  TodayPresent, TodayAbsent, OverdueFees.
  Added at the end (extra columns are ignored by existing Dapper mappings):
  TotalSubjects, FeesOutstandingAmount, FeesCollectedThisMonth.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetDashboardStats
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);

    SELECT (SELECT COUNT(*)
              FROM dbo.Students AS s
              INNER JOIN dbo.Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
             WHERE s.SchoolId = @SchoolId AND s.IsActive = 1 AND u.IsActive = 1) AS TotalStudents,

           (SELECT COUNT(*)
              FROM dbo.Teachers AS t
              INNER JOIN dbo.Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
             WHERE t.SchoolId = @SchoolId AND t.IsActive = 1 AND u.IsActive = 1) AS TotalTeachers,

           (SELECT COUNT(*)
              FROM dbo.Parents AS p
              INNER JOIN dbo.Users AS u ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
             WHERE p.SchoolId = @SchoolId AND p.IsActive = 1 AND u.IsActive = 1) AS TotalParents,

           (SELECT COUNT(*) FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND IsActive = 1) AS TotalClasses,

           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND AttendanceDate = @Today AND IsPresent = 1) AS TodayPresent,

           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND AttendanceDate = @Today AND IsPresent = 0) AS TodayAbsent,

           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId
               AND f.IsActive = 1
               AND f.DueDate < @Today
               AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees,

           (SELECT COUNT(*) FROM dbo.Subjects
             WHERE SchoolId = @SchoolId AND IsActive = 1) AS TotalSubjects,

           (SELECT ISNULL(SUM(f.Amount - ISNULL(p.Paid, 0)), 0)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId
               AND f.IsActive = 1
               AND ISNULL(p.Paid, 0) < f.Amount) AS FeesOutstandingAmount,

           (SELECT ISNULL(SUM(AmountPaid), 0)
              FROM dbo.FeePayments
             WHERE SchoolId = @SchoolId
               AND PaymentStatus = 'Completed'
               AND PaymentDate >= @MonthStart) AS FeesCollectedThisMonth;
END
GO

SET NOEXEC OFF;
GO
