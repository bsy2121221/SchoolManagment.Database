/*==============================================================================
  StoredProcedure : dbo.sp_GetRolePermissions
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
  sp_GetRolePermissions -- the CanView/CanCreate/CanEdit/CanDelete grid.

  A module with no row is absent from the result, which the API reads as "no
  access". Nothing is invented here so an empty grid stays visibly empty.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRolePermissions
    @RoleId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.RoleId,
           r.RoleName,
           p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete,
           p.IsActive,
           p.CreatedBy,
           p.ModifiedBy,
           p.CreatedAt,
           p.UpdatedAt
    FROM dbo.RolePermissions AS p
    INNER JOIN dbo.Roles AS r ON r.Id = p.RoleId
    WHERE (@RoleId IS NULL OR p.RoleId = @RoleId)
    ORDER BY p.RoleId, p.ModuleName;
END
GO

SET NOEXEC OFF;
GO
