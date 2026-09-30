/*==============================================================================
  StoredProcedure : dbo.sp_UpdateFee
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

SET NOEXEC OFF;
GO
