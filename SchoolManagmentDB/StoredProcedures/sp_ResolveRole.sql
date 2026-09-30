/*==============================================================================
  StoredProcedure : dbo.sp_ResolveRole
  Extracted from: 02_Functions.sql
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
  sp_ResolveRole -- normalise the "@RoleId or @Role" pair the write procedures
  accept, so callers on either the old string API or the new id API both work.

  @RoleId wins when both are supplied. Throws rather than returning a row,
  because every caller is inside a transaction that must not continue.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ResolveRole
    @RoleId         INT             = NULL,
    @Role           NVARCHAR(50)    = NULL,
    @ResolvedRoleId INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @ResolvedRoleId = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    IF @ResolvedRoleId IS NULL
    BEGIN
        THROW 51010, 'A role is required. Pass @RoleId, or @Role as a role name or code.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Id = @ResolvedRoleId AND IsActive = 1)
    BEGIN
        THROW 51011, 'Role not found, or the role is inactive.', 1;
    END
END
GO

SET NOEXEC OFF;
GO
