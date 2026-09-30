/*==============================================================================
  StoredProcedure : dbo.sp_GetFeeCollectionSummary
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
  sp_GetFeeCollectionSummary -- NEW. Collection by month for the finance screen.

  Returns: FeeYear, FeeMonth, FeeCount, Billed, Collected, Outstanding

  Grouped by BILLING PERIOD (the fee's FeeMonth / FeeYear), not by the date
  money arrived. A March fee paid in May counts as collected in March here,
  while the dashboard's FeesCollectedThisMonth counts it in May. Both are
  right; they answer different questions, and the screen says which.
  (FeeCount is new in Phase 12.)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetFeeCollectionSummary
    @SchoolId   INT,
    @FeeYear    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT f.FeeYear,
           f.FeeMonth,
           COUNT(*) AS FeeCount,
           SUM(f.Amount) AS Billed,
           SUM(ISNULL(p.Paid, 0)) AS Collected,
           SUM(f.Amount - ISNULL(p.Paid, 0)) AS Outstanding
    FROM dbo.Fees AS f
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    WHERE f.SchoolId = @SchoolId
      AND f.IsActive = 1
      AND (@FeeYear IS NULL OR f.FeeYear = @FeeYear)
    GROUP BY f.FeeYear, f.FeeMonth
    ORDER BY f.FeeYear DESC, f.FeeMonth DESC;
END
GO

SET NOEXEC OFF;
GO
