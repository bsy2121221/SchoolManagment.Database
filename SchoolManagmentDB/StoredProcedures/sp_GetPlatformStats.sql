/*==============================================================================
  StoredProcedure : dbo.sp_GetPlatformStats
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
  sp_GetPlatformStats -- totals across all tenants, for the SuperAdmin home.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetPlatformStats
AS
BEGIN
    SET NOCOUNT ON;

    SELECT (SELECT COUNT(*) FROM dbo.Schools)                              AS TotalSchools,
           (SELECT COUNT(*) FROM dbo.Schools WHERE IsActive = 1)           AS ActiveSchools,
           (SELECT COUNT(*) FROM dbo.Schools WHERE IsActive = 0)           AS InactiveSchools,
           /* RoleId literals rather than a join: 1..5 are fixed by the Roles seed
              in 01_Schema.sql and named the same way by Constants.RoleIds in C#. */
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 4 AND IsActive = 1) AS TotalStudents,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 3 AND IsActive = 1) AS TotalTeachers,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 5 AND IsActive = 1) AS TotalParents,
           (SELECT COUNT(*) FROM dbo.Users    WHERE RoleId = 2 AND IsActive = 1) AS TotalAdmins,
           (SELECT COUNT(*) FROM dbo.Classes  WHERE IsActive = 1)          AS TotalClasses,
           (SELECT COUNT(*) FROM dbo.Schools WHERE CreatedAt >= DATEADD(DAY, -30, GETDATE())) AS SchoolsAddedLast30Days;
END
GO

SET NOEXEC OFF;
GO
