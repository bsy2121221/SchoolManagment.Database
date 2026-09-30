/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentProfileStats
  Extracted from: 06_Procs_Students.sql
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
  sp_GetStudentProfileStats

  The old version read a StudentFees table with an IsPaid column. No script in
  this project ever created that table, so this procedure failed outright.
  Rewritten against the real Fees + FeePayments pair, where "paid" means the
  completed payments cover the fee amount.

  Column names kept: PresentDays, AbsentDays, TotalDays, TotalResults,
  AverageMarks, HighestMarks, TotalFees, PaidAmount, PendingAmount, SubjectCount
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentProfileStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                               WHERE SchoolId = @SchoolId AND UserId = @UserId);

    SELECT (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsPresent = 1) AS PresentDays,
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsPresent = 0) AS AbsentDays,
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId) AS TotalDays,

           (SELECT COUNT(*) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalResults,
           (SELECT AVG(CAST(ObtainedMarks AS FLOAT)) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS AverageMarks,
           (SELECT MAX(ObtainedMarks) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS HighestMarks,

           (SELECT COUNT(*) FROM dbo.Fees
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalFees,
           (SELECT ISNULL(SUM(fp.AmountPaid), 0)
              FROM dbo.FeePayments AS fp
              INNER JOIN dbo.Fees AS f ON f.SchoolId = fp.SchoolId AND f.Id = fp.FeeId
             WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId
               AND f.IsActive = 1 AND fp.PaymentStatus = 'Completed') AS PaidAmount,
           (SELECT ISNULL(SUM(CASE WHEN f.Amount - ISNULL(p.Paid, 0) > 0
                                   THEN f.Amount - ISNULL(p.Paid, 0) ELSE 0 END), 0)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId AND f.IsActive = 1) AS PendingAmount,

           (SELECT COUNT(*) FROM dbo.StudentSubjects
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS SubjectCount;
END
GO

SET NOEXEC OFF;
GO
