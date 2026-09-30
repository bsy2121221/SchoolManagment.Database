/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentSubjects
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
  sp_GetStudentSubjects

  Id is the SUBJECT's id now. It used to be StudentSubjects.Id, and because
  SubjectDTO's first property is Id, Dapper filled it with the link row's id --
  so the unassign button sent the wrong number and removed nothing. The link id
  is still here as StudentSubjectId for anything that needs the row itself.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentSubjects
    @SchoolId   INT,
    @StudentId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT sub.Id,
           sub.SubjectName,
           sub.SubjectCode,
           sub.Grade,
           ss.Id AS StudentSubjectId,
           ss.StudentId,
           ss.SubjectId,
           ss.IsActive,
           ss.CreatedAt
    FROM dbo.StudentSubjects AS ss
    INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
    WHERE ss.SchoolId = @SchoolId
      AND ss.StudentId = @StudentId
      AND ss.IsActive = 1
    ORDER BY sub.SubjectName;
END
GO

SET NOEXEC OFF;
GO
