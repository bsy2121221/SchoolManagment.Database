/*==============================================================================
  StoredProcedure : dbo.sp_GetFeeDetails
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
  sp_GetFeeDetails
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetFeeDetails
    @SchoolId   INT,
    @FeeId      INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    /* PHASE 12: StudentId is Students.Id now and the admission number is
       StudentNumber, as everywhere else in this file. FeeTypeId and Status are
       new, so the detail row can be read without a second call. */
    SELECT f.Id,
           f.Amount,
           f.DueDate,
           f.FeeMonth,
           f.FeeYear,
           f.FeeTypeId,
           ft.FeeTypeName,
           ft.Description,
           s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
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
    INNER JOIN dbo.Students AS s  ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
    INNER JOIN dbo.vw_Users AS u  ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    WHERE f.SchoolId = @SchoolId
      AND f.Id = @FeeId
      AND f.IsActive = 1;
END
GO

SET NOEXEC OFF;
GO
