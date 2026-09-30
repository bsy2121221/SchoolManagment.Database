/*==============================================================================
  StoredProcedure : dbo.sp_DeleteParent
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
  sp_DeleteParent -- soft delete, refusing to orphan history.

  Returns: Result

  A parent who has recorded a fee payment is kept, exactly as a student with
  attendance is: FeePayments.PaidBy is a FK to Users, and the receipt has to keep
  naming somebody. Their children links are deactivated along with the account,
  following sp_DeleteStudent -- the alternative, refusing while any child is
  linked, would force an admin to unlink three children by hand before they could
  deactivate one duplicate record.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteParent
    @SchoolId           INT,
    @ParentId           INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Parents
                                WHERE SchoolId = @SchoolId AND Id = @ParentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.FeePayments
                    WHERE SchoolId = @SchoolId AND PaidBy = @UserId)
        BEGIN
            SELECT 'Error: Cannot delete a parent who has recorded fee payments. Deactivate the account instead.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentParents SET IsActive = 0
         WHERE SchoolId = @SchoolId AND ParentId = @ParentId;

        UPDATE dbo.Parents SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ParentId;

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
            @Action = 'Parent.Delete', @EntityType = 'Parent', @EntityId = @ParentId;

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
