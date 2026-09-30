/*==============================================================================
  StoredProcedure : dbo.sp_UpdateRole
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
  sp_UpdateRole -- rename or deactivate a role.

  A system role may have its description edited but not its name, code or active
  flag: the application refers to those by value, and CK_Users_SchoolScope
  depends on role 1 continuing to exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateRole
    @RoleId         INT,
    @RoleName       NVARCHAR(50)    = NULL,
    @Description    NVARCHAR(255)   = NULL,
    @IsActive       BIT             = NULL,
    @ModifiedBy     INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @IsSystemRole BIT, @CurrentName NVARCHAR(50);
        SELECT @IsSystemRole = IsSystemRole, @CurrentName = RoleName
        FROM dbo.Roles WHERE Id = @RoleId;

        IF @IsSystemRole IS NULL
        BEGIN
            SELECT 'Error: Role not found.' AS Result;
            RETURN;
        END

        SET @RoleName = NULLIF(LTRIM(RTRIM(ISNULL(@RoleName, N''))), N'');

        /* PHASE 14: RoleUpdateDTO always carries the name, so resending the
           current one is "no rename", not a rename. Before this, every update
           of a system role -- description included -- was refused. The
           comparison is case-sensitive: recasing "admin" is still a rename. */
        IF @RoleName COLLATE Latin1_General_BIN = @CurrentName COLLATE Latin1_General_BIN
            SET @RoleName = NULL;

        IF @IsSystemRole = 1 AND (@RoleName IS NOT NULL OR @IsActive = 0)
        BEGIN
            SELECT 'Error: A system role cannot be renamed or deactivated.' AS Result;
            RETURN;
        END

        IF @RoleName IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = @RoleName AND Id <> @RoleId)
        BEGIN
            SELECT 'Error: Role ''' + @RoleName + ''' already exists.' AS Result;
            RETURN;
        END

        /* Deactivating a role would leave its holders unable to log in, so block
           it while anyone still has it. */
        IF @IsActive = 0 AND EXISTS (SELECT 1 FROM dbo.Users WHERE RoleId = @RoleId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Active users still hold this role. Reassign them first.' AS Result;
            RETURN;
        END

        UPDATE dbo.Roles
           SET RoleName    = ISNULL(@RoleName, RoleName),
               /* NULL keeps the description; a blank string clears it. */
               Description = CASE WHEN @Description IS NULL THEN Description
                                  ELSE NULLIF(LTRIM(RTRIM(@Description)), N'') END,
               IsActive    = ISNULL(@IsActive, IsActive),
               ModifiedBy  = ISNULL(@ModifiedBy, ModifiedBy),
               UpdatedAt   = GETDATE()
         WHERE Id = @RoleId;

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @ModifiedBy,
            @Action = 'Role.Update', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @CurrentName;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
