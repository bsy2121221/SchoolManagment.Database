/*==============================================================================
  StoredProcedure : dbo.sp_ChangeUserRole
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
  sp_ChangeUserRole -- move a user to a different role.

  Kept apart from sp_UpdateUser: a role change is an authorisation event, not a
  profile edit, and it has to invalidate the user's tokens. Their old JWT still
  carries the old role and the old permission grid until it expires, so the
  sessions are revoked and the user re-authenticates.

  SuperAdmin is not reachable from here in either direction -- CK_Users_SchoolScope
  requires SchoolId IS NULL for role 1, and this procedure is school-scoped.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ChangeUserRole
    @SchoolId   INT,
    @UserId     INT,
    @RoleId     INT = NULL,
    @Role       NVARCHAR(50) = NULL,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @CurrentRoleId INT;

        SELECT @CurrentRoleId = RoleId
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId;

        IF @CurrentRoleId IS NULL
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        DECLARE @NewRoleId INT;
        EXEC dbo.sp_ResolveRole @RoleId = @RoleId, @Role = @Role,
                                @ResolvedRoleId = @NewRoleId OUTPUT;

        IF @NewRoleId = 1
        BEGIN
            SELECT 'Error: SuperAdmin cannot be assigned to a school user.' AS Result;
            RETURN;
        END

        IF @NewRoleId = @CurrentRoleId
        BEGIN
            SELECT 'Success' AS Result;   -- already there; nothing to do
            RETURN;
        END

        /* Students, Teachers and Parents carry role-specific rows keyed on UserId.
           Moving a user out of one of those roles would leave that row behind
           pointing at someone who is no longer, say, a teacher. */
        IF @CurrentRoleId IN (3, 4, 5)
        BEGIN
            SELECT 'Error: Students, teachers and parents cannot be reassigned to another role. '
                 + 'Deactivate this account and create the new one.' AS Result;
            RETURN;
        END

        IF @NewRoleId IN (3, 4, 5)
        BEGIN
            SELECT 'Error: Use the student, teacher or parent registration procedure '
                 + 'to create those accounts.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET RoleId     = @NewRoleId,
               ModifiedBy = ISNULL(@ModifiedBy, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE Id = @UserId AND SchoolId = @SchoolId;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        DECLARE @Details NVARCHAR(200) =
            dbo.fn_RoleName(@CurrentRoleId) + N' -> ' + dbo.fn_RoleName(@NewRoleId);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @ModifiedBy,
            @Action = 'User.RoleChange', @EntityType = 'User', @EntityId = @UserId,
            @Details = @Details;

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
