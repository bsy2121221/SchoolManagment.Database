/*==============================================================================
  StoredProcedure : dbo.sp_AssignSubjectsToTeacher
  Extracted from: 07_Procs_Teachers.sql
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
  sp_AssignSubjectsToTeacher

  @Silent = 1 suppresses the result set so this can be called from inside
  another procedure without shadowing the outer one's output.

  Returns (when not silent): Result, SubjectsAssigned
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignSubjectsToTeacher
    @SchoolId   INT,
    @TeacherId  INT,              -- Teachers.Id
    @SubjectIds NVARCHAR(MAX),    -- comma-separated
    @Silent     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Teachers WHERE SchoolId = @SchoolId AND Id = @TeacherId)
        BEGIN
            IF @Silent = 0
                SELECT 'Error: Teacher not found in this school' AS Result, 0 AS SubjectsAssigned;
            RETURN;
        END

        DECLARE @Wanted TABLE (SubjectId INT PRIMARY KEY);

        /* Only this school's subjects survive the join, so a stray id from
           another tenant is dropped instead of raising an FK error. */
        INSERT INTO @Wanted (SubjectId)
        SELECT DISTINCT sub.Id
        FROM STRING_SPLIT(ISNULL(@SubjectIds, N''), ',') AS parts
        INNER JOIN dbo.Subjects AS sub
                ON sub.Id = TRY_CONVERT(INT, LTRIM(RTRIM(parts.value)))
               AND sub.SchoolId = @SchoolId
        WHERE TRY_CONVERT(INT, LTRIM(RTRIM(parts.value))) IS NOT NULL;

        BEGIN TRANSACTION;

        MERGE dbo.TeacherSubjects AS tgt
        USING (SELECT @SchoolId AS SchoolId, @TeacherId AS TeacherId, SubjectId FROM @Wanted) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.TeacherId = src.TeacherId
            AND tgt.SubjectId = src.SubjectId
        WHEN MATCHED THEN
            UPDATE SET IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, TeacherId, SubjectId, IsActive)
            VALUES (src.SchoolId, src.TeacherId, src.SubjectId, 1);

        UPDATE dbo.TeacherSubjects
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND TeacherId = @TeacherId
           AND SubjectId NOT IN (SELECT SubjectId FROM @Wanted);

        DECLARE @Count INT = (SELECT COUNT(*) FROM dbo.TeacherSubjects
                               WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1);

        COMMIT TRANSACTION;

        IF @Silent = 0
            SELECT 'Success' AS Result, @Count AS SubjectsAssigned;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @Silent = 0
            SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS SubjectsAssigned;
        ELSE
            THROW;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
