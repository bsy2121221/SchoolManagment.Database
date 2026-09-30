/*==============================================================================
  11_Procs_Fees.sql  --  Fee types, student fees, payments, outstanding reports.

  NEW: sp_CreateFeeType / sp_UpdateFeeType / sp_DeleteFeeType.
  FeeTypes was seeded once by a setup script and had no management procedures, so
  a school could not add a fee head of its own. (sp_CreateSchool seeds seven per
  school; these let each school change them.)

  FIXES
    * "Paid so far" was SUM(AmountPaid) over ALL payment rows, ignoring
      PaymentStatus -- a Failed or Refunded payment still counted as money
      received and could mark a fee paid. Every balance calculation here counts
      only PaymentStatus = 'Completed'.
    * sp_MakeFeePayment read the balance, then inserted, with no transaction and
      no lock. Two cashiers taking the last instalment at the same time both saw
      the same balance and both succeeded, overpaying the fee. The read now takes
      an UPDLOCK inside a transaction.
    * Payments got no receipt number. They now get a per-school one from
      SchoolSequences: DPSNOIDA_RCPT_2025_000123.

  PHASE 12 (frontend Fees module)
    * NEW sp_GetFeeTypeById. FeeRepository passed @FeeTypeId to sp_GetFeeTypes,
      which has no such parameter, so GET fee-types/{id} raised on every call.
    * NEW sp_CancelFee. A fee billed by mistake could not be withdrawn at all,
      and because sp_DeleteFeeType refuses while any active fee references the
      type, one mistaken bill also pinned its fee type forever.
    * NEW sp_AssignFeeToClass. Billing was one student at a time only.
    * sp_GetFeeDetails / sp_GetPaymentHistory return StudentId = Students.Id and
      StudentNumber = the admission number, matching sp_GetOutstandingFees and
      sp_GetReceipt. They returned the admission number AS StudentId, so the
      same column name meant two different things across four procedures.
    * sp_GetPaymentHistory takes @StartDate / @EndDate (the repository was
      already sending them and the call failed), and names the cashier.
    * sp_GetReceipt looks up by @ReceiptNumber as well as @PaymentId. The
      receipt number is the thing printed on paper; the id is not.
    * sp_UpdateFee takes @UserId and writes an audit row. Changing what a
      student owes was the one money-moving write that left no trace.
    * sp_MakeFeePayment says what the balance is when it refuses an overpayment,
      and refuses a fee already paid in full in its own words.
    * sp_GetOutstandingFees no longer drops departed students. The dashboard's
      FeesOutstandingAmount counts them, so the two screens disagreed on what
      the school is owed. They are returned with StudentIsActive = 0 instead.
      Also takes @FeeTypeId, which the controller already advertised.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  --------------------------------- FEE TYPES ---------------------------------
==============================================================================*/

/*==============================================================================
  sp_GetFeeTypes
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetFeeTypes
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, FeeTypeName, Description, DefaultAmount, IsActive, SchoolId
    FROM dbo.FeeTypes
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY FeeTypeName;
END
GO

/*==============================================================================
  sp_GetFeeTypeById -- PHASE 12. One active fee type, or no row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetFeeTypeById
    @SchoolId   INT,
    @FeeTypeId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, FeeTypeName, Description, DefaultAmount, IsActive, SchoolId
    FROM dbo.FeeTypes
    WHERE SchoolId = @SchoolId
      AND Id = @FeeTypeId
      AND IsActive = 1;
END
GO

/*==============================================================================
  sp_CreateFeeType -- NEW. Returns: Result, FeeTypeId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateFeeType
    @SchoolId       INT,
    @FeeTypeName    NVARCHAR(100),
    @Description    NVARCHAR(255) = NULL,
    @DefaultAmount  DECIMAL(10,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        SET @FeeTypeName = LTRIM(RTRIM(ISNULL(@FeeTypeName, N'')));

        IF @FeeTypeName = N''
        BEGIN
            SELECT 'Error: Fee type name is required' AS Result, CAST(NULL AS INT) AS FeeTypeId;
            RETURN;
        END

        /* UQ_FeeTypes_School_Name covers soft-deleted rows too, so reuse the
           existing row instead of colliding on the constraint. */
        DECLARE @Existing INT = (SELECT Id FROM dbo.FeeTypes
                                  WHERE SchoolId = @SchoolId AND FeeTypeName = @FeeTypeName);

        IF @Existing IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.FeeTypes WHERE Id = @Existing AND IsActive = 1)
            BEGIN
                SELECT 'Error: A fee type with this name already exists' AS Result,
                       CAST(NULL AS INT) AS FeeTypeId;
                RETURN;
            END

            UPDATE dbo.FeeTypes
               SET Description   = @Description,
                   DefaultAmount = @DefaultAmount,
                   IsActive      = 1,
                   UpdatedAt     = GETDATE()
             WHERE Id = @Existing;

            SELECT 'Success' AS Result, @Existing AS FeeTypeId;
            RETURN;
        END

        INSERT INTO dbo.FeeTypes (SchoolId, FeeTypeName, Description, DefaultAmount)
        VALUES (@SchoolId, @FeeTypeName, @Description, @DefaultAmount);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS FeeTypeId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS FeeTypeId;
    END CATCH
END
GO

/*==============================================================================
  sp_UpdateFeeType -- NEW. Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateFeeType
    @SchoolId       INT,
    @FeeTypeId      INT,
    @FeeTypeName    NVARCHAR(100),
    @Description    NVARCHAR(255) = NULL,
    @DefaultAmount  DECIMAL(10,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.FeeTypes
                        WHERE SchoolId = @SchoolId AND Id = @FeeTypeId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Fee type not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.FeeTypes
                    WHERE SchoolId = @SchoolId AND FeeTypeName = @FeeTypeName AND Id <> @FeeTypeId)
        BEGIN
            SELECT 'Error: A fee type with this name already exists' AS Result;
            RETURN;
        END

        /* Only the default for FUTURE fees changes. Amounts already billed live
           on the Fees rows and are deliberately left alone -- rewriting them
           would change what students have already been invoiced. */
        UPDATE dbo.FeeTypes
           SET FeeTypeName   = @FeeTypeName,
               Description   = @Description,
               DefaultAmount = @DefaultAmount,
               UpdatedAt     = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @FeeTypeId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteFeeType -- NEW. Soft delete, blocked while fees reference it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteFeeType
    @SchoolId   INT,
    @FeeTypeId  INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.FeeTypes
                        WHERE SchoolId = @SchoolId AND Id = @FeeTypeId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Fee type not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Fees
                    WHERE SchoolId = @SchoolId AND FeeTypeId = @FeeTypeId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete a fee type that has active fees against it' AS Result;
            RETURN;
        END

        UPDATE dbo.FeeTypes SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @FeeTypeId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  ------------------------------------ FEES ------------------------------------
==============================================================================*/

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

/*==============================================================================
  sp_UpdateFee -- correct an amount or due date. Returns: Result

  PHASE 12: @UserId and an audit row. The old and new amounts go in Details,
  because the Fees row itself keeps only the latest value.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateFee
    @SchoolId   INT,
    @FeeId      INT,
    @Amount     DECIMAL(10,2),
    @DueDate    DATE,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @OldAmount DECIMAL(10,2), @OldDue DATE;

        SELECT @OldAmount = Amount, @OldDue = DueDate
        FROM dbo.Fees
        WHERE SchoolId = @SchoolId AND Id = @FeeId AND IsActive = 1;

        IF @OldAmount IS NULL
        BEGIN
            SELECT 'Error: Fee not found in this school' AS Result;
            RETURN;
        END

        IF @Amount IS NULL OR @Amount <= 0
        BEGIN
            SELECT 'Error: Amount must be greater than zero' AS Result;
            RETURN;
        END

        IF @DueDate IS NULL
        BEGIN
            SELECT 'Error: Due date is required' AS Result;
            RETURN;
        END

        DECLARE @Paid DECIMAL(10,2) = ISNULL((SELECT SUM(AmountPaid) FROM dbo.FeePayments
                                               WHERE SchoolId = @SchoolId AND FeeId = @FeeId
                                                 AND PaymentStatus = 'Completed'), 0);

        /* Cutting the amount below what has already been collected would leave a
           negative balance with no way to represent the refund. */
        IF @Amount < @Paid
        BEGIN
            SELECT 'Error: Amount cannot be less than the ' + CAST(@Paid AS NVARCHAR(20))
                 + ' already paid' AS Result;
            RETURN;
        END

        UPDATE dbo.Fees
           SET Amount    = @Amount,
               DueDate   = @DueDate,
               UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @FeeId;

        DECLARE @Details NVARCHAR(MAX) = CONCAT(
            'Amount ', @OldAmount, ' -> ', @Amount,
            '; DueDate ', CONVERT(CHAR(10), @OldDue, 23), ' -> ', CONVERT(CHAR(10), @DueDate, 23));

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Fee.Update', @EntityType = 'Fee', @EntityId = @FeeId,
            @Details = @Details;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_CancelFee -- PHASE 12. Withdraw a fee billed by mistake. Returns: Result

  Refused while any Completed payment stands against the fee: cancelling it
  would make money the school has taken disappear from every balance. Refund
  the payments first, then cancel.

  The row is deactivated, not deleted, so its refunded payments and their
  receipt numbers stay reconcilable. UX_Fees_School_Student_Type_Period covers
  inactive rows too, which is why both assign procedures revive a cancelled row
  rather than inserting a second one.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CancelFee
    @SchoolId   INT,
    @FeeId      INT,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Fees
                        WHERE SchoolId = @SchoolId AND Id = @FeeId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Fee not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.FeePayments
                    WHERE SchoolId = @SchoolId AND FeeId = @FeeId
                      AND PaymentStatus = 'Completed')
        BEGIN
            SELECT 'Error: This fee has payments against it. Refund them before cancelling the fee' AS Result;
            RETURN;
        END

        UPDATE dbo.Fees SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @FeeId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Fee.Cancel', @EntityType = 'Fee', @EntityId = @FeeId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_AssignFeeToClass -- PHASE 12. Bill one fee to every active student in a
  class. Returns: Result, FeesCreated, FeesSkipped

  A student already billed this fee type for this period is skipped, not
  failed, and counted in FeesSkipped. A cancelled fee for the same period is
  revived with the new amount and due date, since the unique index would refuse
  a second row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignFeeToClass
    @SchoolId   INT,
    @ClassId    INT,
    @FeeTypeId  INT,
    @Amount     DECIMAL(10,2),
    @DueDate    DATE,
    @FeeMonth   INT = NULL,
    @FeeYear    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.FeeTypes
                        WHERE SchoolId = @SchoolId AND Id = @FeeTypeId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Fee type not found in this school' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        IF @Amount IS NULL OR @Amount <= 0
        BEGIN
            SELECT 'Error: Amount must be greater than zero' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        IF @DueDate IS NULL
        BEGIN
            SELECT 'Error: Due date is required' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        SET @FeeMonth = ISNULL(@FeeMonth, MONTH(@DueDate));
        SET @FeeYear  = ISNULL(@FeeYear,  YEAR(@DueDate));

        IF @FeeMonth NOT BETWEEN 1 AND 12 OR @FeeYear NOT BETWEEN 2000 AND 2200
        BEGIN
            SELECT 'Error: Billing period is out of range' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        DECLARE @Students TABLE (StudentId INT PRIMARY KEY);

        INSERT INTO @Students (StudentId)
        SELECT Id FROM dbo.Students
        WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1;

        DECLARE @Requested INT = (SELECT COUNT(*) FROM @Students);

        IF @Requested = 0
        BEGIN
            SELECT 'Error: This class has no active students to bill' AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE f
           SET IsActive = 1, Amount = @Amount, DueDate = @DueDate, UpdatedAt = GETDATE()
        FROM dbo.Fees AS f
        INNER JOIN @Students AS st ON st.StudentId = f.StudentId
        WHERE f.SchoolId = @SchoolId AND f.FeeTypeId = @FeeTypeId
          AND f.FeeMonth = @FeeMonth AND f.FeeYear = @FeeYear
          AND f.IsActive = 0;

        DECLARE @Revived INT = @@ROWCOUNT;

        INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        SELECT @SchoolId, st.StudentId, @FeeTypeId, @Amount, @DueDate, @FeeMonth, @FeeYear
        FROM @Students AS st
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Fees AS f
                           WHERE f.SchoolId = @SchoolId AND f.StudentId = st.StudentId
                             AND f.FeeTypeId = @FeeTypeId
                             AND f.FeeMonth = @FeeMonth AND f.FeeYear = @FeeYear);

        DECLARE @Created INT = @@ROWCOUNT + @Revived;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @Created AS FeesCreated, @Requested - @Created AS FeesSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS FeesCreated, 0 AS FeesSkipped;
    END CATCH
END
GO

/*==============================================================================
  --------------------------------- PAYMENTS ----------------------------------
==============================================================================*/

/*==============================================================================
  sp_MakeFeePayment

  Returns: Result, PaymentId, ReceiptNumber
  (Result and PaymentId are unchanged; ReceiptNumber is new.)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_MakeFeePayment
    @SchoolId       INT,
    @FeeId          INT,
    @AmountPaid     DECIMAL(10,2),
    @PaymentMethod  NVARCHAR(50),
    @TransactionId  NVARCHAR(100) = NULL,
    @Remarks        NVARCHAR(255) = NULL,
    @PaidBy         INT,
    @PaymentStatus  NVARCHAR(20) = 'Completed'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF @AmountPaid IS NULL OR @AmountPaid <= 0
        BEGIN
            SELECT 'Error: Payment amount must be greater than zero' AS Result,
                   CAST(NULL AS INT) AS PaymentId, CAST(NULL AS NVARCHAR(40)) AS ReceiptNumber;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* UPDLOCK on the fee row serialises concurrent payments against the same
           fee, so the balance we read cannot be spent twice. */
        DECLARE @Amount DECIMAL(10,2);

        SELECT @Amount = f.Amount
        FROM dbo.Fees AS f WITH (UPDLOCK, ROWLOCK)
        WHERE f.SchoolId = @SchoolId AND f.Id = @FeeId AND f.IsActive = 1;

        IF @Amount IS NULL
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Fee not found' AS Result,
                   CAST(NULL AS INT) AS PaymentId, CAST(NULL AS NVARCHAR(40)) AS ReceiptNumber;
            RETURN;
        END

        DECLARE @Paid DECIMAL(10,2) = ISNULL((SELECT SUM(AmountPaid) FROM dbo.FeePayments
                                               WHERE SchoolId = @SchoolId AND FeeId = @FeeId
                                                 AND PaymentStatus = 'Completed'), 0);

        DECLARE @Balance DECIMAL(10,2) = @Amount - @Paid;

        /* PHASE 12: both refusals name the figure. "Cannot exceed balance" with
           no number sent the cashier back to another screen to find out what
           the balance was, and a fee paid in full is its own case -- the
           second click of a double-submitted payment lands here. */
        IF @PaymentStatus = 'Completed' AND @Balance <= 0
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: This fee is already paid in full' AS Result,
                   CAST(NULL AS INT) AS PaymentId, CAST(NULL AS NVARCHAR(40)) AS ReceiptNumber;
            RETURN;
        END

        IF @PaymentStatus = 'Completed' AND @AmountPaid > @Balance
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Payment amount cannot exceed the outstanding balance of '
                   + CAST(@Balance AS NVARCHAR(20)) AS Result,
                   CAST(NULL AS INT) AS PaymentId, CAST(NULL AS NVARCHAR(40)) AS ReceiptNumber;
            RETURN;
        END

        DECLARE @Seq INT;
        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = N'Receipt', @NextValue = @Seq OUTPUT;

        DECLARE @Receipt NVARCHAR(40) = dbo.fn_GenerateReceiptNumber(
            dbo.fn_SchoolCode(@SchoolId), YEAR(GETDATE()), @Seq);

        INSERT INTO dbo.FeePayments (SchoolId, FeeId, ReceiptNumber, AmountPaid, PaymentDate,
                                     PaymentMethod, TransactionId, PaymentStatus, Remarks, PaidBy)
        VALUES (@SchoolId, @FeeId, @Receipt, @AmountPaid, CAST(GETDATE() AS DATE),
                @PaymentMethod, @TransactionId, @PaymentStatus, @Remarks, @PaidBy);

        DECLARE @PaymentId INT = CAST(SCOPE_IDENTITY() AS INT);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PaidBy,
            @Action = 'Fee.Payment', @EntityType = 'FeePayment', @EntityId = @PaymentId,
            @Details = @Receipt;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @PaymentId AS PaymentId, @Receipt AS ReceiptNumber;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS PaymentId, CAST(NULL AS NVARCHAR(40)) AS ReceiptNumber;
    END CATCH
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

/*==============================================================================
  sp_RefundPayment -- mark a payment refunded rather than deleting it.

  Deleting the row would erase the receipt number and make the ledger
  unreconcilable; flipping the status removes it from every balance because all
  the sums here filter on 'Completed'.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RefundPayment
    @SchoolId   INT,
    @PaymentId  INT,
    @Remarks    NVARCHAR(255) = NULL,
    @UserId     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.FeePayments
                        WHERE SchoolId = @SchoolId AND Id = @PaymentId
                          AND PaymentStatus = 'Completed')
        BEGIN
            SELECT 'Error: Completed payment not found in this school' AS Result;
            RETURN;
        END

        UPDATE dbo.FeePayments
           SET PaymentStatus = 'Refunded',
               Remarks       = ISNULL(@Remarks, Remarks)
         WHERE SchoolId = @SchoolId AND Id = @PaymentId;

        DECLARE @RefundDetails NVARCHAR(1000) =
            (SELECT CONCAT(ReceiptNumber, ': ', AmountPaid) FROM dbo.FeePayments
              WHERE SchoolId = @SchoolId AND Id = @PaymentId);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Fee.Refund', @EntityType = 'FeePayment', @EntityId = @PaymentId,
            @Details = @RefundDetails;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
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

PRINT '=== 11_Procs_Fees.sql complete ===';
GO

SET NOEXEC OFF;
GO
