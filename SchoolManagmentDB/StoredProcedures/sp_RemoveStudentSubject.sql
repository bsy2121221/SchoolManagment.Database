/*==============================================================================
  StoredProcedure : dbo.sp_RemoveStudentSubject
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
  sp_RemoveStudentSubject -- NEW. Unassign one subject from one student.

  The link is deactivated, not deleted, for the same reason everything else here
  is a soft delete: results and attendance recorded against the subject stay
  readable, and re-assigning it later revives this row rather than tripping
  UQ_StudentSubjects.

  Already-unassigned is reported as success. The caller asked for a state, not
  for an event, and a double-click on the unassign button should not produce an
  error the user cannot act on.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RemoveStudentSubject
    @SchoolId   INT,
    @StudentId  INT,          -- Students.Id
    @SubjectId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.StudentSubjects
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                          AND SubjectId = @SubjectId)
        BEGIN
            SELECT 'Error: That subject is not assigned to this student' AS Result;
            RETURN;
        END

        UPDATE dbo.StudentSubjects
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND StudentId = @StudentId
           AND SubjectId = @SubjectId
           AND IsActive = 1;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
