/*==============================================================================
  StoredProcedure : dbo.sp_CreateStudentFee
  Extracted from: 06_Procs_Students.sql
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
  sp_CreateStudentFee -- Returns: Result, FeeId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateStudentFee
    @SchoolId   INT,
    @StudentId  INT,
    @FeeTypeId  INT,
    @Amount     DECIMAL(10,2),
    @DueDate    DATE,
    @FeeMonth   INT,
    @FeeYear    INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result, CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.FeeTypes WHERE SchoolId = @SchoolId AND Id = @FeeTypeId)
        BEGIN
            SELECT 'Error: Fee type not found in this school' AS Result, CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Fees
                    WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                      AND FeeTypeId = @FeeTypeId AND FeeMonth = @FeeMonth AND FeeYear = @FeeYear)
        BEGIN
            SELECT 'Error: Fee already exists for this student, type, month, and year' AS Result,
                   CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        VALUES (@SchoolId, @StudentId, @FeeTypeId, @Amount, @DueDate, @FeeMonth, @FeeYear);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS FeeId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS FeeId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
