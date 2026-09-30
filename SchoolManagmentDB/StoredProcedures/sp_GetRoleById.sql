/*==============================================================================
  StoredProcedure : dbo.sp_GetRoleById
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
  sp_GetRoleById -- one role plus its permission grid, as two result sets.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRoleById
    @RoleId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id,
           r.RoleName,
           r.RoleCode,
           r.Description,
           r.IsSystemRole,
           r.IsActive,
           (SELECT COUNT(*) FROM dbo.Users AS u WHERE u.RoleId = r.Id) AS UserCount,
           (SELECT COUNT(*) FROM dbo.RolePermissions AS p WHERE p.RoleId = r.Id
                                                            AND p.IsActive = 1
                                                            AND p.CanView = 1) AS ModuleCount,
           r.CreatedBy,
           cb.Username AS CreatedByUsername,
           r.ModifiedBy,
           mb.Username AS ModifiedByUsername,
           r.CreatedAt,
           r.UpdatedAt
    FROM dbo.Roles AS r
    LEFT JOIN dbo.Users AS cb ON cb.Id = r.CreatedBy
    LEFT JOIN dbo.Users AS mb ON mb.Id = r.ModifiedBy
    WHERE r.Id = @RoleId;

    EXEC dbo.sp_GetRolePermissions @RoleId = @RoleId;
END
GO

SET NOEXEC OFF;
GO
