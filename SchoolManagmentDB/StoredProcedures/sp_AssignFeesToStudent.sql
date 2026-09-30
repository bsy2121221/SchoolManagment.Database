/*==============================================================================
  StoredProcedure : dbo.sp_AssignFeesToStudent
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
  sp_AssignFeesToStudent -- NOW ACTUALLY WRITES.

  The old version was a stub: it returned 'Success' without touching the Fees
  table, so "assign fees" appeared to work and nothing was ever billed.

  @FeeAssignments is the JSON shape the old signature documented:
      [{"FeeTypeId":1,"Amount":1500,"DueDate":"2026-01-31","FeeMonth":1,"FeeYear":2026}]

  Duplicates for the same student / type / period are skipped rather than
  failing the batch (UX_Fees_School_Student_Type_Period enforces this anyway).

  PHASE 12: FeesCreated + FeesSkipped always equals the number of array
  elements sent. Malformed rows, out-of-range periods, inactive fee types and
  in-batch duplicates are all skipped and counted; a cancelled fee for the same
  period is revived.

  Returns: Result, Message, FeesCreated, FeesSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignFeesToStudent
    @SchoolId       INT,
    @StudentId      INT,
    @FeeAssignments NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result,
                   'Student not found' AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Students
                    WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 0)
        BEGIN
            SELECT 'Error: This student is no longer active and cannot be billed' AS Result,
                   'Student inactive' AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        /* An array specifically: a bare object passes ISJSON, and OPENJSON would
           then count its keys as though they were rows. */
        IF ISJSON(ISNULL(@FeeAssignments, N'')) <> 1
           OR LEFT(LTRIM(@FeeAssignments), 1) <> N'['
        BEGIN
            SELECT 'Error: FeeAssignments is not valid JSON' AS Result,
                   'Expected [{"FeeTypeId":1,"Amount":1500,"DueDate":"2026-01-31","FeeMonth":1,"FeeYear":2026}]' AS Message,
                   0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        /* PHASE 12: @Requested is the length of the array as sent, counted
           BEFORE any filtering. It used to be counted after the NULL filter,
           so a row with no DueDate vanished from both counts and a batch of
           three with one malformed row reported "2 created, 0 skipped". */
        DECLARE @Requested INT = (SELECT COUNT(*) FROM OPENJSON(@FeeAssignments));

        DECLARE @Rows TABLE (
            FeeTypeId INT, Amount DECIMAL(10,2), DueDate DATE, FeeMonth INT, FeeYear INT
        );

        /* Rows that would violate CK_Fees_* are dropped here and counted as
           skipped, rather than reaching the INSERT and failing the whole batch
           on a CHECK constraint. Two rows for the same type and period in one
           batch keep only the first -- the unique index would refuse the
           second and, again, take the batch with it. */
        INSERT INTO @Rows (FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        SELECT FeeTypeId, Amount, DueDate, FeeMonth, FeeYear
        FROM (
            SELECT v.*, ROW_NUMBER() OVER (PARTITION BY v.FeeTypeId, v.FeeMonth, v.FeeYear
                                           ORDER BY v.Ord) AS Rn
            FROM (
                SELECT CAST(j.[key] AS INT) AS Ord,
                       x.FeeTypeId, x.Amount, x.DueDate,
                       ISNULL(x.FeeMonth, MONTH(x.DueDate)) AS FeeMonth,
                       ISNULL(x.FeeYear,  YEAR(x.DueDate))  AS FeeYear
                FROM OPENJSON(@FeeAssignments) AS j
                CROSS APPLY OPENJSON(j.[value])
                     WITH (FeeTypeId INT       '$.FeeTypeId',
                           Amount    DECIMAL(10,2) '$.Amount',
                           DueDate   DATE      '$.DueDate',
                           FeeMonth  INT       '$.FeeMonth',
                           FeeYear   INT       '$.FeeYear') AS x
            ) AS v
            WHERE v.FeeTypeId IS NOT NULL
              AND v.Amount IS NOT NULL AND v.Amount > 0
              AND v.DueDate IS NOT NULL
              AND v.FeeMonth BETWEEN 1 AND 12
              AND v.FeeYear BETWEEN 2000 AND 2200
        ) AS d
        WHERE d.Rn = 1;

        BEGIN TRANSACTION;

        /* A cancelled fee (sp_CancelFee) for the same type and period still
           occupies UX_Fees_School_Student_Type_Period, so it is revived with
           the new amount and due date instead of colliding with it. */
        UPDATE f
           SET IsActive = 1, Amount = r.Amount, DueDate = r.DueDate, UpdatedAt = GETDATE()
        FROM dbo.Fees AS f
        INNER JOIN @Rows AS r
                ON r.FeeTypeId = f.FeeTypeId AND r.FeeMonth = f.FeeMonth AND r.FeeYear = f.FeeYear
        INNER JOIN dbo.FeeTypes AS ft
                ON ft.SchoolId = @SchoolId AND ft.Id = r.FeeTypeId AND ft.IsActive = 1
        WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId AND f.IsActive = 0;

        DECLARE @Revived INT = @@ROWCOUNT;

        INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        SELECT @SchoolId, @StudentId, r.FeeTypeId, r.Amount, r.DueDate, r.FeeMonth, r.FeeYear
        FROM @Rows AS r
        /* Only this school's ACTIVE fee types, so a stray id cannot bill
           against another tenant's pricing or a deleted fee head. */
        INNER JOIN dbo.FeeTypes AS ft
                ON ft.SchoolId = @SchoolId AND ft.Id = r.FeeTypeId AND ft.IsActive = 1
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Fees AS f
                           WHERE f.SchoolId = @SchoolId
                             AND f.StudentId = @StudentId
                             AND f.FeeTypeId = r.FeeTypeId
                             AND f.FeeMonth = r.FeeMonth
                             AND f.FeeYear = r.FeeYear);

        DECLARE @Created INT = @@ROWCOUNT + @Revived;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               'Fees assigned successfully' AS Message,
               @Created AS FeesCreated,
               @Requested - @Created AS FeesSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               ERROR_MESSAGE() AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
