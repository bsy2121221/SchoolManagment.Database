/*==============================================================================
  StoredProcedure : dbo.sp_DeleteUser
  Extracted from: 05_Procs_Users.sql
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
  sp_DeleteUser -- soft delete, refusing to orphan historical data.

  Same guard rails as before (no deleting admins, no deleting anyone with
  attendance / results / fees), with two corrections:
    * the teacher checks used Classes.ClassTeacherId = @UserId, but that column
      now holds Teachers.Id, so the user id is resolved first;
    * every check is scoped to @SchoolId.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteUser
    @SchoolId           INT,
    @UserId             INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        /* RoleId literals: 1 SuperAdmin, 2 Admin, 3 Teacher, 4 Student, 5 Parent,
           fixed by the Roles seed in 01_Schema.sql. @UserRole is kept for the audit
           details. */
        DECLARE @RoleId INT, @UserRole NVARCHAR(50);

        SELECT @RoleId = RoleId, @UserRole = dbo.fn_RoleName(RoleId)
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId AND IsActive = 1;

        IF @RoleId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        IF @RoleId IN (1, 2)
        BEGIN
            SELECT 'Error: Cannot delete admin users' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        IF @RoleId = 3
        BEGIN
            DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                                       WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete teacher who is assigned to active classes' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Attendance
                        WHERE SchoolId = @SchoolId AND MarkedBy = @UserId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete teacher who has historical attendance data' AS Result;
                RETURN;
            END

            UPDATE dbo.Teachers
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

            UPDATE dbo.TeacherSubjects SET IsActive = 0
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

            UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

            UPDATE dbo.TeacherSchedule SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;
        END
        ELSE IF @RoleId = 4
        BEGIN
            DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                                       WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.Attendance
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with attendance records. This student has historical data.' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Results
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with exam results. This student has historical data.' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Fees
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with fee records. This student has historical data.' AS Result;
                RETURN;
            END

            UPDATE dbo.Students
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

            UPDATE dbo.StudentSubjects SET IsActive = 0
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId;
        END
        ELSE IF @RoleId = 5
        BEGIN
            DECLARE @ParentId INT = (SELECT Id FROM dbo.Parents
                                      WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.StudentParents
                        WHERE SchoolId = @SchoolId AND ParentId = @ParentId AND IsActive = 1)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete parent with active children relationships' AS Result;
                RETURN;
            END

            UPDATE dbo.Parents
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        END

        UPDATE dbo.Users
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId AND SchoolId = @SchoolId;

        /* The person row follows the account: Users.PersonId is unique, so this
           person exists only to be this user. The row is kept, not deleted --
           attendance and results still reference the user id behind it. */
        UPDATE dbo.Persons
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = (SELECT PersonId FROM dbo.Users WHERE Id = @UserId);

        /* A deactivated user must not keep a working session. */
        UPDATE dbo.RefreshTokens
           SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'User.Delete', @EntityType = 'User', @EntityId = @UserId,
            @Details = @UserRole;

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
