/*==============================================================================
  StoredProcedure : dbo.sp_GetPaymentHistory
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
  sp_GetPaymentHistory

  PHASE 12: @StartDate / @EndDate (inclusive, on PaymentDate) so the same
  procedure serves one student's history and the school-wide ledger.
  StudentId is Students.Id now; the admission number is StudentNumber.
  ClassName and ReceivedBy are new. Refunded and failed rows are included --
  this is a ledger, and a refund is part of it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetPaymentHistory
    @SchoolId   INT,
    @StudentId  INT = NULL,
    @FeeId      INT = NULL,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT fp.Id,
           fp.ReceiptNumber,
           fp.AmountPaid,
           fp.PaymentDate,
           fp.PaymentMethod,
           fp.TransactionId,
           fp.PaymentStatus,
           fp.Remarks,
           f.Id AS FeeId,
           f.FeeMonth,
           f.FeeYear,
           f.Amount AS TotalAmount,
           ft.FeeTypeName,
           s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           c.ClassName,
           NULLIF(LTRIM(CONCAT(cu.FirstName, ' ', cu.LastName)), '') AS ReceivedBy,
           fp.SchoolId
    FROM dbo.FeePayments AS fp
    INNER JOIN dbo.Fees     AS f  ON f.SchoolId = fp.SchoolId AND f.Id = fp.FeeId
    INNER JOIN dbo.FeeTypes AS ft ON ft.SchoolId = f.SchoolId AND ft.Id = f.FeeTypeId
    INNER JOIN dbo.Students AS s  ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
    INNER JOIN dbo.vw_Users AS u  ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN  dbo.Classes  AS c  ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN  dbo.vw_Users AS cu ON cu.SchoolId = fp.SchoolId AND cu.Id = fp.PaidBy
    WHERE fp.SchoolId = @SchoolId
      AND (@StudentId IS NULL OR f.StudentId = @StudentId)
      AND (@FeeId IS NULL OR f.Id = @FeeId)
      AND (@StartDate IS NULL OR fp.PaymentDate >= @StartDate)
      AND (@EndDate IS NULL OR fp.PaymentDate <= @EndDate)
    ORDER BY fp.PaymentDate DESC, fp.Id DESC;
END
GO

SET NOEXEC OFF;
GO
