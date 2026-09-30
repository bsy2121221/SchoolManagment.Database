/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherClasses
  Extracted from: 07_Procs_Teachers.sql
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
  sp_GetTeacherClasses -- @TeacherId is Teachers.Id (was Users.Id).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherClasses
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           COUNT(s.Id) AS StudentCount
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Students AS s
           ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND c.ClassTeacherId = @TeacherId
      AND c.IsActive = 1
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section;
END
GO

SET NOEXEC OFF;
GO
