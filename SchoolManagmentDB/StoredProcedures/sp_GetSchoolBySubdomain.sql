/*==============================================================================
  StoredProcedure : dbo.sp_GetSchoolBySubdomain
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
  sp_GetSchoolBySubdomain -- resolve a wildcard host to a tenant.

  For the *.yourdomain.com deployment: the API reads the Host header, passes the
  leading label here, and uses the result to brand the login page. Only public
  fields, so this may be called anonymously.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolBySubdomain
    @Subdomain NVARCHAR(63)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id AS SchoolId,
           SchoolCode,
           SchoolName,
           Subdomain,
           LogoUrl,
           ThemeColor,
           IsActive
    FROM dbo.Schools
    WHERE Subdomain = LOWER(LTRIM(RTRIM(@Subdomain)));
END
GO

SET NOEXEC OFF;
GO
