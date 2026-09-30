/*==============================================================================
  StoredProcedure : dbo.sp_DeleteSubject
  Extracted from: 10_Procs_Academics.sql
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
  sp_DeleteSubject -- NEW. Soft delete, blocked by examination history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteSubject
    @SchoolId   INT,
    @SubjectId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Examinations
                    WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete a subject with active examinations. Remove the examinations first.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSchedule SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.Subjects SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @SubjectId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  -------------------------------- EXAMINATIONS --------------------------------
==============================================================================*/

SET NOEXEC OFF;
GO
