/*==============================================================================
  StoredProcedure : dbo.sp_DeleteRolePermission
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
  sp_DeleteRolePermission -- revoke a module from a role outright.

  Removes the row rather than clearing the four flags, so the grid distinguishes
  "explicitly nothing" from "never configured". Both deny; only one shows intent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteRolePermission
    @RoleId     INT,
    @ModuleName NVARCHAR(50),
    @DeletedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* PHASE 14: the SuperAdmin's grid is not consulted -- the permission
           handler short-circuits role 1 -- but the UI builds its menus from
           it, so an edit here could only hide screens the server still
           serves. */
        IF @RoleId = 1
        BEGIN
            SELECT 'Error: The SuperAdmin role always has every permission; its grid cannot be changed.' AS Result;
            RETURN;
        END

        DELETE FROM dbo.RolePermissions
        WHERE RoleId = @RoleId AND ModuleName = @ModuleName;

        IF @@ROWCOUNT = 0
        BEGIN
            SELECT 'Error: No permission row for that role and module.' AS Result;
            RETURN;
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @DeletedBy,
            @Action = 'Role.PermissionRevoke', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @ModuleName;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
