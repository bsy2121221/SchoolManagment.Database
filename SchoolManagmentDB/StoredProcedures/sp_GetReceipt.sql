/*==============================================================================
  StoredProcedure : dbo.sp_GetReceipt
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
  sp_GetReceipt -- one payment, everything a printed receipt needs.

  PHASE 12: by @PaymentId or by @ReceiptNumber (the one printed on paper and
  the one a parent reads back over the phone). StudentId, FeeId and the fee's
  current Balance are new; Balance is as of now, not as of the payment, and
  the receipt screen labels it that way.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetReceipt
    @SchoolId       INT,
    @PaymentId      INT = NULL,
    @ReceiptNumber  NVARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* Neither key given: the WHERE below matches nothing and an empty result
       set comes back. No early RETURN, because a procedure that returns no
       result set at all makes Dapper throw rather than read "not found". */
    SELECT fp.Id AS PaymentId,
           fp.ReceiptNumber,
           fp.AmountPaid,
           fp.PaymentDate,
           fp.PaymentMethod,
           fp.TransactionId,
           fp.PaymentStatus,
           fp.Remarks,
           f.Amount AS FeeAmount,
           f.FeeMonth,
           f.FeeYear,
           f.DueDate,
           f.Id AS FeeId,
           ft.FeeTypeName,
           s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           c.ClassName,
           c.Grade,
           c.Section,
           NULLIF(LTRIM(CONCAT(cu.FirstName, ' ', cu.LastName)), '') AS ReceivedBy,
           ISNULL(p.Paid, 0) AS FeeTotalPaid,
           f.Amount - ISNULL(p.Paid, 0) AS FeeBalance,
           sch.SchoolName,
           sch.SchoolCode,
           sch.Address AS SchoolAddress,
           sch.ContactPhone AS SchoolPhone
    FROM dbo.FeePayments AS fp
    INNER JOIN dbo.Fees     AS f   ON f.SchoolId = fp.SchoolId AND f.Id = fp.FeeId
    INNER JOIN dbo.FeeTypes AS ft  ON ft.SchoolId = f.SchoolId AND ft.Id = f.FeeTypeId
    INNER JOIN dbo.Students AS s   ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
    INNER JOIN dbo.vw_Users AS u   ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN  dbo.Classes  AS c   ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN  dbo.vw_Users AS cu  ON cu.SchoolId = fp.SchoolId AND cu.Id = fp.PaidBy
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    INNER JOIN dbo.Schools  AS sch ON sch.Id = fp.SchoolId
    WHERE fp.SchoolId = @SchoolId
      AND (@PaymentId IS NOT NULL OR @ReceiptNumber IS NOT NULL)
      AND (@PaymentId IS NULL OR fp.Id = @PaymentId)
      AND (@ReceiptNumber IS NULL OR fp.ReceiptNumber = @ReceiptNumber);
END
GO

SET NOEXEC OFF;
GO
