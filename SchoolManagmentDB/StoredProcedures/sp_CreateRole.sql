/*==============================================================================
  StoredProcedure : dbo.sp_CreateRole
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
  sp_CreateRole -- add a custom role.

  Ids >= 100 by CK_Roles_Id: the 1..5 band is reserved for the system roles that
  CK_Users_SchoolScope and Constants.RoleIds refer to by number. Because the
  column is not IDENTITY, the next id is computed here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateRole
    @RoleName       NVARCHAR(50),
    @RoleCode       NVARCHAR(20)    = NULL,
    @Description    NVARCHAR(255)   = NULL,
    @CreatedBy      INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        SET @RoleName = NULLIF(LTRIM(RTRIM(ISNULL(@RoleName, N''))), N'');
        SET @RoleCode = NULLIF(LTRIM(RTRIM(ISNULL(@RoleCode, N''))), N'');
        SET @RoleCode = ISNULL(@RoleCode, LEFT(dbo.fn_SanitizeCode(@RoleName), 20));

        IF @RoleName IS NULL
        BEGIN
            SELECT 'Error: Role name is required.' AS Result, CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        /* PHASE 14: a name with no letters or digits ("---") sanitises to an
           empty code, which the first such role would take and every later one
           would collide with under a confusing message. */
        IF @RoleCode = N''
        BEGIN
            SELECT 'Error: A role code could not be derived from that name. Supply one.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = @RoleName)
        BEGIN
            SELECT 'Error: Role ''' + @RoleName + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleCode = @RoleCode)
        BEGIN
            SELECT 'Error: Role code ''' + @RoleCode + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS RoleId;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* HOLDLOCK on the MAX makes two concurrent creates queue rather than
           both pick the same id. */
        DECLARE @RoleId INT =
            (SELECT ISNULL(MAX(Id), 99) + 1 FROM dbo.Roles WITH (UPDLOCK, HOLDLOCK) WHERE Id >= 100);

        INSERT INTO dbo.Roles (Id, RoleName, RoleCode, Description, IsSystemRole,
                               IsActive, CreatedBy, ModifiedBy)
        VALUES (@RoleId, @RoleName, @RoleCode, @Description, 0, 1, @CreatedBy, @CreatedBy);

        EXEC dbo.sp_LogAudit
            @SchoolId = NULL, @UserId = @CreatedBy,
            @Action = 'Role.Create', @EntityType = 'Role', @EntityId = @RoleId,
            @Details = @RoleName;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @RoleId AS RoleId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS RoleId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
