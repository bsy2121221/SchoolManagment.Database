/*==============================================================================
  StoredProcedure : dbo.sp_UpdateFeeType
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

SET NOEXEC OFF;
GO
