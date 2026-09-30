/*==============================================================================
  StoredProcedure : dbo.sp_GetSchoolBranding
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
  sp_GetSchoolBranding -- public branding only. Safe for anonymous callers.

  Deliberately excludes contact details, counts and anything else a competitor
  or scraper should not be able to enumerate.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolBranding
    @SchoolId   INT = NULL,
    @SchoolCode NVARCHAR(12) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id AS SchoolId,
           SchoolCode,
           SchoolName,
           LogoUrl,
           ThemeColor,
           IsActive
    FROM dbo.Schools
    WHERE (@SchoolId IS NOT NULL AND Id = @SchoolId)
       OR (@SchoolId IS NULL AND @SchoolCode IS NOT NULL
           AND SchoolCode = dbo.fn_SanitizeCode(@SchoolCode));
END
GO

SET NOEXEC OFF;
GO
