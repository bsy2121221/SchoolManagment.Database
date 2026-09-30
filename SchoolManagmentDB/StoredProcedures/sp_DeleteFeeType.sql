/*==============================================================================
  StoredProcedure : dbo.sp_DeleteFeeType
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

SET NOEXEC OFF;
GO
