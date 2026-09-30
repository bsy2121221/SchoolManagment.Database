/*==============================================================================
  StoredProcedure : dbo.sp_RefundPayment
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

SET NOEXEC OFF;
GO
