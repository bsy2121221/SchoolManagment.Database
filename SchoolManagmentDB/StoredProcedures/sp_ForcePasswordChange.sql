/*==============================================================================
  StoredProcedure : dbo.sp_ForcePasswordChange
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
  sp_ForcePasswordChange -- admin resets a user in their own school.

  @SchoolId is checked against the target user, so a School A admin cannot
  reset a School B user even with a guessed user id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ForcePasswordChange
    @SchoolId           INT,
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255) = NULL,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND SchoolId = @SchoolId)
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        SET @NewPasswordHash = ISNULL(@NewPasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash = @NewPasswordHash,
               RequirePasswordChange = 1,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId
           AND SchoolId = @SchoolId;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
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
