/*==============================================================================
  StoredProcedure : dbo.sp_CreateFeeType
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

SET NOEXEC OFF;
GO
