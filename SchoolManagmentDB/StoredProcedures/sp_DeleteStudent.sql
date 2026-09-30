/*==============================================================================
  StoredProcedure : dbo.sp_DeleteStudent
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
  sp_DeleteStudent -- soft delete, refusing to orphan history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteStudent
    @SchoolId           INT,
    @StudentId          INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Students
                                WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Attendance WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
           OR EXISTS (SELECT 1 FROM dbo.Results WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
           OR EXISTS (SELECT 1 FROM dbo.Fees    WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
        BEGIN
            SELECT 'Error: Cannot delete student with attendance, result or fee history. Deactivate the account instead.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND StudentId = @StudentId;

        UPDATE dbo.StudentParents SET IsActive = 0
         WHERE SchoolId = @SchoolId AND StudentId = @StudentId;

        UPDATE dbo.Students SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @StudentId;

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
            @Action = 'Student.Delete', @EntityType = 'Student', @EntityId = @StudentId;

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
