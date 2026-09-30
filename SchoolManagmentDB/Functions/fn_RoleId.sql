/*==============================================================================
  Function : dbo.fn_RoleId
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
  fn_RoleId -- role name OR role code -> Roles.Id. NULL if no such role.

  Accepts either spelling so a caller can pass the JWT's 'Teacher' or the
  database's 'TEACHER' without knowing which it holds.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_RoleId (@Role NVARCHAR(50))
RETURNS INT
AS
BEGIN
    SET @Role = NULLIF(LTRIM(RTRIM(ISNULL(@Role, N''))), N'');
    IF @Role IS NULL RETURN NULL;

    RETURN (SELECT TOP (1) Id
            FROM dbo.Roles
            WHERE IsActive = 1
              AND (RoleName = @Role OR RoleCode = @Role)
            ORDER BY Id);
END
GO

SET NOEXEC OFF;
GO
