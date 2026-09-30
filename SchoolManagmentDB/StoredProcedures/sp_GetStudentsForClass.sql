/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentsForClass
  Extracted from: 06_Procs_Students.sql
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
  sp_GetStudentsForClass -- lightweight list for attendance and grade screens.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsForClass
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           u.Email,
           s.ClassId,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
