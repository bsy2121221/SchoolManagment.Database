/*==============================================================================
  StoredProcedure : dbo.sp_GetOutstandingFees
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
  sp_GetOutstandingFees -- NEW. Who owes what, optionally by class.

  Returns: FeeId, StudentId, StudentNumber, RollNumber, FirstName, LastName,
           StudentIsActive, ClassId, ClassName, Grade, Section, FeeTypeId,
           FeeTypeName, Amount, TotalPaid, Balance, DueDate, FeeMonth, FeeYear,
           DaysOverdue, Status

  PHASE 12: departed students are included and flagged by StudentIsActive,
  rather than filtered out. They still owe the money, and the dashboard's
  FeesOutstandingAmount counts them -- filtering here made this screen's total
  smaller than the dashboard's with nothing to say why. ClassId is NULL for a
  student with no class. @FeeTypeId is new.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetOutstandingFees
    @SchoolId       INT,
    @ClassId        INT = NULL,
    @OverdueOnly    BIT = 0,
    @FeeTypeId      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT f.Id AS FeeId,
           s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           s.IsActive AS StudentIsActive,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           f.FeeTypeId,
           ft.FeeTypeName,
           f.Amount,
           ISNULL(p.Paid, 0) AS TotalPaid,
           f.Amount - ISNULL(p.Paid, 0) AS Balance,
           f.DueDate,
           f.FeeMonth,
           f.FeeYear,
           CASE WHEN f.DueDate < @Today THEN DATEDIFF(DAY, f.DueDate, @Today) ELSE 0 END AS DaysOverdue,
           CASE WHEN f.DueDate < @Today THEN 'Overdue' ELSE 'Pending' END AS Status
    FROM dbo.Fees AS f
    INNER JOIN dbo.Students AS s  ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
    INNER JOIN dbo.vw_Users AS u  ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    INNER JOIN dbo.FeeTypes AS ft ON ft.SchoolId = f.SchoolId AND ft.Id = f.FeeTypeId
    LEFT JOIN  dbo.Classes  AS c  ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    WHERE f.SchoolId = @SchoolId
      AND f.IsActive = 1
      AND ISNULL(p.Paid, 0) < f.Amount
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND (@FeeTypeId IS NULL OR f.FeeTypeId = @FeeTypeId)
      AND (@OverdueOnly = 0 OR f.DueDate < @Today)
    ORDER BY f.DueDate, TRY_CONVERT(INT, c.Grade), c.Grade, c.Section,
             TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
