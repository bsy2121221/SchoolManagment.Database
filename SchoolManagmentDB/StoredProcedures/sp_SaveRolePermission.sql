/*==============================================================================
  StoredProcedure : dbo.sp_SaveRolePermission
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
  sp_SaveRolePermission -- set one (role, module) cell of the grid.

  Insert-or-update on (RoleId, ModuleName), matching UQ_RolePermissions_Role_Module,
  so the API can send the whole grid one row at a time and stay idempotent.

  CanView is forced on when any of create/edit/delete is granted: editing
  something you cannot see is not a state the UI can represent, and
  CK_RolePermissions_ViewImplied would reject it anyway.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SaveRolePermission
    @RoleId         INT,
    @ModuleName     NVARCHAR(50),
    @CanView        BIT = 0,
    @CanCreate      BIT = 0,
    @CanEdit        BIT = 0,
    @CanDelete      BIT = 0,
    @IsActive       BIT = 1,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @ModuleName = NULLIF(LTRIM(RTRIM(ISNULL(@ModuleName, N''))), N'');

        IF @ModuleName IS NULL
        BEGIN
            SELECT 'Error: Module name is required.' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Id = @RoleId)
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        /* PHASE 14: the SuperAdmin's grid is not consulted -- the permission
           handler short-circuits role 1 -- but the UI builds its menus from
           it, so an edit here could only hide screens the server still
           serves. */
        IF @RoleId = 1
        BEGIN
            SELECT 'Error: The SuperAdmin role always has every permission; its grid cannot be changed.' AS Result;
            RETURN;
        END

        IF @CanCreate = 1 OR @CanEdit = 1 OR @CanDelete = 1 SET @CanView = 1;

        IF EXISTS (SELECT 1 FROM dbo.RolePermissions
                    WHERE RoleId = @RoleId AND ModuleName = @ModuleName)
        BEGIN
            UPDATE dbo.RolePermissions
               SET CanView    = @CanView,
                   CanCreate  = @CanCreate,
                   CanEdit    = @CanEdit,
                   CanDelete  = @CanDelete,
                   IsActive   = @IsActive,
                   ModifiedBy = ISNULL(@ModifiedBy, ModifiedBy),
                   UpdatedAt  = GETDATE()
             WHERE RoleId = @RoleId AND ModuleName = @ModuleName;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.RolePermissions (RoleId, ModuleName, CanView, CanCreate, CanEdit,
                                             CanDelete, IsActive, CreatedBy, ModifiedBy)
            VALUES (@RoleId, @ModuleName, @CanView, @CanCreate, @CanEdit,
                    @CanDelete, @IsActive, @ModifiedBy, @ModifiedBy);
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @ModifiedBy,
            @Action = 'Role.Permission', @EntityType = 'Role', @EntityId = @RoleId,
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
