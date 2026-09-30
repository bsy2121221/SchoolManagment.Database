/*==============================================================================
  SeedData/Roles.sql — system reference roles (required for a usable schema).

  Seeded here (not only in demo InitialData) because CK_Users_SchoolScope names
  RoleId 1, so the schema is not self-consistent without these five rows.
  Role Ids are a contract mirrored by Constants.RoleIds in C#.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

IF EXISTS (SELECT 1 FROM dbo.Roles WHERE Id = 1)
BEGIN
    PRINT '*** Roles already seeded. Skipping. ***';
    SET NOEXEC ON;
END
GO

INSERT INTO dbo.Roles (Id, RoleName, RoleCode, Description, IsSystemRole)
VALUES (1, N'SuperAdmin', N'SUPERADMIN', N'Platform operator. Belongs to no school; manages every tenant.', 1),
       (2, N'Admin',      N'ADMIN',      N'School administrator. Full control within their own school.',      1),
       (3, N'Teacher',    N'TEACHER',    N'Teaching staff. Attendance, grades and their own timetable.',       1),
       (4, N'Student',    N'STUDENT',    N'Enrolled student. Reads their own records.',                        1),
       (5, N'Parent',     N'PARENT',     N'Guardian. Reads the records of their linked children.',             1);
GO

PRINT '=== SeedData/Roles.sql complete ===';
GO

SET NOEXEC OFF;
GO