/*==============================================================================
  StoredProcedure : dbo.sp_MakeFeePayment
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

SET NOEXEC OFF;
GO
