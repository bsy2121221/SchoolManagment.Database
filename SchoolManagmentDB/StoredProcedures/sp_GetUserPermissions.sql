/*==============================================================================
  StoredProcedure : dbo.sp_GetUserPermissions
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
  sp_GetUserPermissions -- the effective grid for one user, for the JWT.

  Called on login and on refresh, so the token carries the permissions and the
  per-request authorisation check needs no database round trip.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserPermissions
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.Users AS u
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = u.RoleId
    WHERE u.Id = @UserId
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

SET NOEXEC OFF;
GO
