/*==============================================================================
  StoredProcedure : dbo.sp_DeleteTeacher
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
  sp_DeleteTeacher -- soft delete.

  The class guard compared ClassTeacherId to the teacher's Users.Id, which never
  matched, so a teacher owning classes could be deleted and those classes were
  left pointing at a deactivated row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteTeacher
    @SchoolId           INT,
    @TeacherId          INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Teachers
                                WHERE SchoolId = @SchoolId AND Id = @TeacherId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete teacher who is assigned to active classes' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Attendance WHERE SchoolId = @SchoolId AND MarkedBy = @UserId)
        BEGIN
            SELECT 'Error: Cannot delete teacher who has historical attendance data' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.TeacherSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.TeacherSchedule SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.Teachers SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @TeacherId;

        UPDATE dbo.Users
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @UserId;

        UPDATE dbo.Persons
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = (SELECT PersonId FROM dbo.Users WHERE Id = @UserId);

        UPDATE dbo.RefreshTokens SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Teacher.Delete', @EntityType = 'Teacher', @EntityId = @TeacherId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
