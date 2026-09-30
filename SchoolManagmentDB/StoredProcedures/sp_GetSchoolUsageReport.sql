/*==============================================================================
  StoredProcedure : dbo.sp_GetSchoolUsageReport
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
  sp_GetSchoolUsageReport -- per-school activity, for billing or capacity work.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchoolUsageReport
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ToDate   = ISNULL(@ToDate, CAST(GETDATE() AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -30, @ToDate));

    SELECT s.Id AS SchoolId,
           s.SchoolCode,
           s.SchoolName,
           s.IsActive,
           (SELECT COUNT(*) FROM dbo.Students   AS x WHERE x.SchoolId = s.Id AND x.IsActive = 1) AS ActiveStudents,
           (SELECT COUNT(*) FROM dbo.Teachers   AS x WHERE x.SchoolId = s.Id AND x.IsActive = 1) AS ActiveTeachers,
           (SELECT COUNT(*) FROM dbo.Attendance AS x WHERE x.SchoolId = s.Id AND x.AttendanceDate BETWEEN @FromDate AND @ToDate) AS AttendanceRecords,
           (SELECT COUNT(*) FROM dbo.Results    AS x WHERE x.SchoolId = s.Id AND CAST(x.CreatedAt AS DATE) BETWEEN @FromDate AND @ToDate) AS ResultsEntered,
           (SELECT ISNULL(SUM(x.AmountPaid), 0) FROM dbo.FeePayments AS x
             WHERE x.SchoolId = s.Id AND x.PaymentStatus = 'Completed'
               AND x.PaymentDate BETWEEN @FromDate AND @ToDate) AS FeesCollected,
           (SELECT MAX(u.LastLoginAt) FROM dbo.Users AS u WHERE u.SchoolId = s.Id) AS LastLoginAt
    FROM dbo.Schools AS s
    ORDER BY s.SchoolName;
END
GO

/*==============================================================================
  SECTION -- ROLES AND ROLE PERMISSIONS

  Roles are global (no SchoolId), so they live in this file with the other
  tenant-free objects. Ids 1..5 are the system roles seeded by 01_Schema.sql and
  cannot be renamed or deleted; anything a school adds gets Id >= 100.
==============================================================================*/

SET NOEXEC OFF;
GO
