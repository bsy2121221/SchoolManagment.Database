/*==============================================================================
  StoredProcedure : dbo.sp_CancelFee
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

SET NOEXEC OFF;
GO
