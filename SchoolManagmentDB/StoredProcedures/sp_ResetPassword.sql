/*==============================================================================
  StoredProcedure : dbo.sp_ResetPassword
  Extracted from: 04_Procs_Auth.sql
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
  sp_ResetPassword -- admin resets another user's password.

  Called by AuthRepository.ResetPasswordAsync, which had no matching procedure.
  @SchoolId NULL means "the caller is a SuperAdmin, skip the tenant check";
  anything else confines the reset to that school.

  Delegates the work to sp_ForcePasswordChange for a user inside a school so the
  revoke-sessions and audit behaviour stays in one place.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ResetPassword
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255),
    @SchoolId           INT = NULL,
    @PerformedByUserId  INT = NULL,
    @RequirePasswordChange BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @TargetSchoolId INT;
        SELECT @TargetSchoolId = SchoolId FROM dbo.Users WHERE Id = @UserId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId)
        BEGIN
            SELECT 'Error: User not found.' AS Result;
            RETURN;
        END

        /* A school admin may only reset within their own school. NULL @SchoolId
           is the SuperAdmin path and is not restricted. */
        IF @SchoolId IS NOT NULL AND ISNULL(@TargetSchoolId, -1) <> @SchoolId
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash          = @NewPasswordHash,
               RequirePasswordChange = @RequirePasswordChange,
               ModifiedBy            = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt             = GETDATE()
         WHERE Id = @UserId;

        /* A reset ends every existing session for that user. */
        UPDATE dbo.RefreshTokens
           SET IsActive  = 0,
               RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @TargetSchoolId, @UserId = @PerformedByUserId,
            @Action = 'Auth.PasswordReset', @EntityType = 'User', @EntityId = @UserId;

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
