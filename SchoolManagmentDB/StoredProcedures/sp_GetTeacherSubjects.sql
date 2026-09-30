/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherSubjects
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
  sp_GetTeacherSubjects -- @TeacherId is Teachers.Id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherSubjects
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.SubjectName,
           s.SubjectCode,
           s.Grade,
           s.IsActive,
           ts.Id AS TeacherSubjectId,
           ts.IsActive AS IsAssigned
    FROM dbo.Subjects AS s
    INNER JOIN dbo.TeacherSubjects AS ts
            ON ts.SchoolId = s.SchoolId AND ts.SubjectId = s.Id
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.IsActive = 1
    ORDER BY s.SubjectName;
END
GO

SET NOEXEC OFF;
GO
