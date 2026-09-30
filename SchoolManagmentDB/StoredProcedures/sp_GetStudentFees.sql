/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentFees
  Extracted from: 11_Procs_Fees.sql
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
  sp_GetStudentFees

  TotalPaid counts only completed payments now.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentFees
    @SchoolId   INT,
    @StudentId  INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT f.Id,
           f.Amount,
           f.DueDate,
           f.FeeMonth,
           f.FeeYear,
           f.FeeTypeId,
           ft.FeeTypeName,
           ft.Description,
           ISNULL(p.Paid, 0) AS TotalPaid,
           f.Amount - ISNULL(p.Paid, 0) AS Balance,
           CASE
             WHEN f.Amount - ISNULL(p.Paid, 0) <= 0 THEN 'Paid'
             WHEN f.DueDate < @Today                THEN 'Overdue'
             ELSE 'Pending'
           END AS Status,
           f.SchoolId
    FROM dbo.Fees AS f
    INNER JOIN dbo.FeeTypes AS ft ON ft.SchoolId = f.SchoolId AND ft.Id = f.FeeTypeId
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    WHERE f.SchoolId = @SchoolId
      AND f.StudentId = @StudentId
      AND f.IsActive = 1
    ORDER BY f.FeeYear DESC, f.FeeMonth DESC;
END
GO

SET NOEXEC OFF;
GO
