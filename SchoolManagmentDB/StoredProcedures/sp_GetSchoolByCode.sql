/*==============================================================================
  StoredProcedure : dbo.sp_GetSchoolByCode
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
  sp_GetSchoolByCode
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolByCode
    @SchoolCode NVARCHAR(12)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SchoolCode, SchoolName, Subdomain, Address, City, State, Country,
           PostalCode, ContactEmail, ContactPhone, PrincipalName, LogoUrl, ThemeColor,
           AcademicYearStartMonth, IsActive, CreatedAt, UpdatedAt
    FROM dbo.Schools
    WHERE SchoolCode = dbo.fn_SanitizeCode(@SchoolCode);
END
GO

SET NOEXEC OFF;
GO
