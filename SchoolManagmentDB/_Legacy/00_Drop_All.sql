/*==============================================================================
  00_Drop_All.sql
  ------------------------------------------------------------------------------
  Tears down every object created by 01..17 so the whole set can be re-run
  from scratch during development.

  Run against the target database, e.g.
      sqlcmd -S .\SQLEXPRESS -E -d SchoolManagementDB -i 00_Drop_All.sql

  WARNING: this deletes all data. There is no backup step here.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/*--- Guard: refuse to run against a system database -------------------------*/
IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    PRINT '*** Select the School Management database first (USE <db> / sqlcmd -d <db>). ***';
    SET NOEXEC ON;
END
GO

PRINT '--- Dropping views ---';
GO

/* Before the tables: vw_Users depends on Users, Persons, Roles and Addresses. */
DROP VIEW IF EXISTS dbo.vw_Users;
GO

PRINT '--- Dropping procedures and functions ---';
GO

/* Every routine in this project is named sp_* or fn_*, so drop by convention.
   This keeps the teardown correct even after procs are added or renamed. */
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'DROP ' +
       CASE WHEN o.type IN ('P', 'PC') THEN N'PROCEDURE ' ELSE N'FUNCTION ' END +
       QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N';' + CHAR(13) + CHAR(10)
FROM sys.objects AS o
WHERE o.type IN ('P', 'PC', 'FN', 'IF', 'TF')
  AND o.is_ms_shipped = 0
  AND (o.name LIKE 'sp[_]%' OR o.name LIKE 'fn[_]%');

IF @sql <> N'' EXEC sys.sp_executesql @sql;
GO

PRINT '--- Dropping foreign keys ---';
GO

/* Drop all FKs first: the composite tenant FKs create a dense dependency
   graph, so dropping tables in a fixed order is fragile. */
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' +
       QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(13) + CHAR(10)
FROM sys.foreign_keys AS fk
JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
WHERE t.name IN (
    'Schools', 'SchoolSequences', 'Roles', 'RolePermissions', 'Persons',
    'Addresses', 'Users', 'Students', 'Teachers', 'Parents',
    'StudentParents', 'Classes', 'Subjects', 'StudentSubjects', 'TeacherSubjects',
    'TeacherSubjectAssignments', 'TeacherSchedule', 'Attendance', 'Examinations',
    'Results', 'FeeTypes', 'Fees', 'FeePayments', 'Settings', 'RefreshTokens',
    'AuditLog'
);

IF @sql <> N'' EXEC sys.sp_executesql @sql;
GO

PRINT '--- Dropping tables ---';
GO

DROP TABLE IF EXISTS dbo.AuditLog;
DROP TABLE IF EXISTS dbo.RefreshTokens;
DROP TABLE IF EXISTS dbo.Settings;
DROP TABLE IF EXISTS dbo.FeePayments;
DROP TABLE IF EXISTS dbo.Fees;
DROP TABLE IF EXISTS dbo.FeeTypes;
DROP TABLE IF EXISTS dbo.Results;
DROP TABLE IF EXISTS dbo.Examinations;
DROP TABLE IF EXISTS dbo.Attendance;
DROP TABLE IF EXISTS dbo.TeacherSchedule;
DROP TABLE IF EXISTS dbo.TeacherSubjectAssignments;
DROP TABLE IF EXISTS dbo.TeacherSubjects;
DROP TABLE IF EXISTS dbo.StudentSubjects;
DROP TABLE IF EXISTS dbo.StudentParents;
DROP TABLE IF EXISTS dbo.Students;
DROP TABLE IF EXISTS dbo.Parents;
DROP TABLE IF EXISTS dbo.Classes;
DROP TABLE IF EXISTS dbo.Teachers;
DROP TABLE IF EXISTS dbo.Subjects;
DROP TABLE IF EXISTS dbo.SchoolSequences;
DROP TABLE IF EXISTS dbo.Users;
DROP TABLE IF EXISTS dbo.Addresses;
DROP TABLE IF EXISTS dbo.Persons;
DROP TABLE IF EXISTS dbo.RolePermissions;
DROP TABLE IF EXISTS dbo.Roles;
DROP TABLE IF EXISTS dbo.Schools;
GO

PRINT '=== 00_Drop_All.sql complete ===';
GO

SET NOEXEC OFF;
GO
