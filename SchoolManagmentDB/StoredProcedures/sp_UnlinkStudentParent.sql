/*==============================================================================
  StoredProcedure : dbo.sp_UnlinkStudentParent
  Extracted from: 17_Procs_Parents.sql
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
  sp_UnlinkStudentParent -- detach a parent from a student.

  Returns: Result

  The mirror of sp_LinkStudentParent, and it follows sp_RemoveStudentSubject on
  the awkward case: no link row at all is an error naming that, while a row that
  is already inactive reports Success, because the caller asked for a state the
  database is already in. The old repository returned `rows > 0` from a bare
  UPDATE, so unlinking twice reported "Failed to unlink parent from student" and
  told the admin nothing about which of the two reasons applied.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UnlinkStudentParent
    @SchoolId           INT,
    @StudentId          INT,
    @ParentId           INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Parents WHERE SchoolId = @SchoolId AND Id = @ParentId)
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.StudentParents
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND ParentId = @ParentId)
        BEGIN
            SELECT 'Error: That parent is not linked to this student' AS Result;
            RETURN;
        END

        UPDATE dbo.StudentParents
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND StudentId = @StudentId
           AND ParentId = @ParentId
           AND IsActive = 1;

        IF @@ROWCOUNT > 0
            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
                @Action = 'Parent.Unlink', @EntityType = 'StudentParent', @EntityId = @StudentId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
