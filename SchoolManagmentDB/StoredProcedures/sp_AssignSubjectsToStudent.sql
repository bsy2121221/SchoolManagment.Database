/*==============================================================================
  StoredProcedure : dbo.sp_AssignSubjectsToStudent
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
  sp_AssignSubjectsToStudent -- NOW ACTUALLY WRITES.

  The old version looped @SubjectIds into a temp table, dropped it, and returned
  'Success' with a comment saying "here you would insert into a StudentSubjects
  table if you had one". Subject counts on the profile page were therefore
  always zero.

  @SubjectIds is a comma-separated list, unchanged, so the API call site does
  not move. Subjects not belonging to @SchoolId are ignored rather than
  triggering an FK error.

  Returns: Result, Message, SubjectsAssigned
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignSubjectsToStudent
    @SchoolId       INT,
    @StudentId      INT,              -- Students.Id
    @SubjectIds     NVARCHAR(MAX),
    @ReplaceExisting BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result,
                   'Student not found' AS Message, 0 AS SubjectsAssigned;
            RETURN;
        END

        DECLARE @Wanted TABLE (SubjectId INT PRIMARY KEY);

        INSERT INTO @Wanted (SubjectId)
        SELECT DISTINCT sub.Id
        FROM STRING_SPLIT(ISNULL(@SubjectIds, N''), ',') AS parts
        INNER JOIN dbo.Subjects AS sub
                ON sub.Id = TRY_CONVERT(INT, LTRIM(RTRIM(parts.value)))
               AND sub.SchoolId = @SchoolId
        WHERE TRY_CONVERT(INT, LTRIM(RTRIM(parts.value))) IS NOT NULL;

        BEGIN TRANSACTION;

        /* Re-activate rather than insert duplicates: UQ_StudentSubjects would
           reject a second row for the same pair after an unassign. */
        MERGE dbo.StudentSubjects AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId, SubjectId FROM @Wanted) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.SubjectId = src.SubjectId
        WHEN MATCHED THEN
            UPDATE SET IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, SubjectId, IsActive)
            VALUES (src.SchoolId, src.StudentId, src.SubjectId, 1);

        IF @ReplaceExisting = 1
        BEGIN
            UPDATE dbo.StudentSubjects
               SET IsActive = 0
             WHERE SchoolId = @SchoolId
               AND StudentId = @StudentId
               AND SubjectId NOT IN (SELECT SubjectId FROM @Wanted);
        END

        DECLARE @Count INT = (SELECT COUNT(*) FROM dbo.StudentSubjects
                               WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1);

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               'Subjects assigned successfully' AS Message,
               @Count AS SubjectsAssigned;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               ERROR_MESSAGE() AS Message, 0 AS SubjectsAssigned;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
