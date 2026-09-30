/*==============================================================================
  StoredProcedure : dbo.sp_GetTeacherSubjectAssignments
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
  sp_GetTeacherSubjectAssignments -- which subject in which class.

  @TeacherId is Teachers.Id. The old table stored a Users.Id here, so this
  procedure and sp_GetTeacherSubjects could never agree on who a teacher was.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherSubjectAssignments
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT tsa.Id,
           tsa.TeacherId,
           tsa.SubjectId,
           tsa.ClassId,
           s.SubjectName,
           s.SubjectCode,
           s.Grade AS SubjectGrade,
           c.ClassName,
           c.Grade AS ClassGrade,
           c.Section,
           COUNT(st.Id) AS StudentCount
    FROM dbo.TeacherSubjectAssignments AS tsa
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = tsa.SchoolId AND s.Id = tsa.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = tsa.SchoolId AND c.Id = tsa.ClassId
    LEFT JOIN dbo.Students  AS st
           ON st.SchoolId = c.SchoolId AND st.ClassId = c.Id AND st.IsActive = 1
    WHERE tsa.SchoolId = @SchoolId
      AND tsa.TeacherId = @TeacherId
      AND tsa.IsActive = 1
      AND s.IsActive = 1
      AND c.IsActive = 1
    GROUP BY tsa.Id, tsa.TeacherId, tsa.SubjectId, tsa.ClassId,
             s.SubjectName, s.SubjectCode, s.Grade,
             c.ClassName, c.Grade, c.Section
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section, s.SubjectName;
END
GO

SET NOEXEC OFF;
GO
