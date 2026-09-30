/*==============================================================================
  StoredProcedure : dbo.sp_DeleteRole
  Extracted from: 03_Procs_Platform.sql
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
  sp_DeleteRole -- remove a custom role and its permission rows.

  A hard delete, because a role nobody holds carries no history worth keeping and
  FK_Users_Role guarantees nothing points at it. System roles are never deletable.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteRole
    @RoleId     INT,
    @DeletedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @IsSystemRole BIT, @RoleName NVARCHAR(50);
        SELECT @IsSystemRole = IsSystemRole, @RoleName = RoleName
        FROM dbo.Roles WHERE Id = @RoleId;

        IF @IsSystemRole IS NULL
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        IF @IsSystemRole = 1
        BEGIN
            SELECT 'Error: A system role cannot be deleted.' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE RoleId = @RoleId)
        BEGIN
            SELECT 'Error: Users still hold this role. Reassign them first.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        DELETE FROM dbo.RolePermissions WHERE RoleId = @RoleId;
        DELETE FROM dbo.Roles           WHERE Id = @RoleId;

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @DeletedBy,
            @Action = 'Role.Delete', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @RoleName;

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
