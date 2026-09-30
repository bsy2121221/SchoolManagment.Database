/*==============================================================================
  SeedData/RolePermissions.sql — default module permission grid for system roles.
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

IF EXISTS (SELECT 1 FROM dbo.RolePermissions)
BEGIN
    PRINT '*** RolePermissions already seeded. Skipping. ***';
    SET NOEXEC ON;
END
GO

;WITH Modules AS (
    SELECT * FROM (VALUES
        (N'Schools'), (N'Users'), (N'Roles'), (N'Students'), (N'Teachers'),
        (N'Parents'), (N'Classes'), (N'Subjects'), (N'Attendance'),
        (N'Examinations'), (N'Results'), (N'Fees'), (N'Schedule'),
        (N'Settings'), (N'Reports')
    ) AS v(ModuleName)
)
INSERT INTO dbo.RolePermissions (RoleId, ModuleName, CanView, CanCreate, CanEdit, CanDelete)
SELECT 1, ModuleName, 1, 1, 1, 1 FROM Modules
UNION ALL
SELECT 2, ModuleName,
       1,
       CASE WHEN ModuleName = N'Schools' THEN 0 ELSE 1 END,
       1,
       CASE WHEN ModuleName IN (N'Schools', N'Roles') THEN 0 ELSE 1 END
FROM Modules
UNION ALL
SELECT 3, ModuleName, 1, 1, 1, 0
FROM Modules WHERE ModuleName IN (N'Attendance', N'Results')
UNION ALL
SELECT 3, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Students', N'Classes', N'Subjects',
                                  N'Examinations', N'Schedule', N'Reports')
UNION ALL
SELECT 4, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Attendance', N'Results', N'Examinations',
                                  N'Fees', N'Schedule', N'Subjects')
UNION ALL
SELECT 5, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Students', N'Attendance', N'Results',
                                  N'Examinations', N'Schedule')
UNION ALL
SELECT 5, N'Fees', 1, 1, 0, 0;
GO

PRINT '=== SeedData/RolePermissions.sql complete ===';
GO

SET NOEXEC OFF;
GO