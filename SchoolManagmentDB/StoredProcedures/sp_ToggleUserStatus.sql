/*==============================================================================
  StoredProcedure : dbo.sp_ToggleUserStatus
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
  sp_ToggleUserStatus
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ToggleUserStatus
    @SchoolId   INT,
    @UserId     INT,
    @IsActive   BIT,
    @UpdatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @RoleId INT, @PersonId INT;

        SELECT @RoleId = RoleId, @PersonId = PersonId
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId;

        IF @RoleId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET IsActive = @IsActive,
               ModifiedBy = ISNULL(@UpdatedBy, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId
           AND SchoolId = @SchoolId;

        UPDATE dbo.Persons
           SET IsActive = @IsActive,
               ModifiedBy = ISNULL(@UpdatedBy, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @PersonId;

        IF @RoleId = 3        -- Teacher
            UPDATE dbo.Teachers SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        ELSE IF @RoleId = 4   -- Student
            UPDATE dbo.Students SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        ELSE IF @RoleId = 5   -- Parent
            UPDATE dbo.Parents SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

        IF @IsActive = 0
            UPDATE dbo.RefreshTokens
               SET IsActive = 0, RevokedAt = GETUTCDATE()
             WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedBy,
            @Action = 'User.ToggleStatus', @EntityType = 'User', @EntityId = @UserId;

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
