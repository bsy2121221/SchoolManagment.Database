/*==============================================================================
  StoredProcedure : dbo.sp_AssignFeeToClass
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

SET NOEXEC OFF;
GO
