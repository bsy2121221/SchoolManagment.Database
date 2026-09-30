/*==============================================================================
  StoredProcedure : dbo.sp_ChangePassword
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
  sp_ChangePassword -- store an already-hashed password.

  @NewPasswordHash must be a BCrypt hash from the API. The old-password check
  also happens in C#, because only C# can verify a BCrypt hash.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ChangePassword
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255),
    @IpAddress          NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId)
        BEGIN
            SELECT 'Error: User not found.' AS Result;
            RETURN;
        END

        DECLARE @SchoolId INT = (SELECT SchoolId FROM dbo.Users WHERE Id = @UserId);

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash = @NewPasswordHash,
               RequirePasswordChange = 0,
               /* Self-service: the user is their own modifier. */
               ModifiedBy = @UserId,
               UpdatedAt = GETDATE()
         WHERE Id = @UserId;

        /* Changing a password invalidates existing sessions. */
        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Auth.PasswordChanged', @EntityType = 'User', @EntityId = @UserId,
            @IpAddress = @IpAddress;

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
