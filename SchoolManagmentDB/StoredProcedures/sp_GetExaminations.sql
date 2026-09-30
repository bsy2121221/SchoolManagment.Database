/*==============================================================================
  StoredProcedure : dbo.sp_GetExaminations
  Extracted from: 10_Procs_Academics.sql
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
  sp_GetExaminations

  StudentCount and ResultsEntered are new columns, and they are here rather than
  in the caller because both questions the list has to answer need them
  together: "how far along is marking" (12 of 30) and "what does deleting this
  destroy" -- sp_DeleteExamination deactivates the results with the exam, so a
  confirmation that cannot name the number of marks about to disappear is asking
  for a decision without the fact that decides it.

  Correlated subqueries rather than GROUP BY joins: an exam's class is fixed, so
  each is a seek on an existing index (IX_Results_School_Exam, and the Students
  class index), and neither can turn one exam into several rows the way a join to
  Results would.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetExaminations
    @SchoolId   INT,
    @ClassId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT e.Id,
           e.ExamName,
           e.ExamType,
           e.ExamDate,
           e.MaxMarks,
           e.PassingMarks,
           e.Duration,
           e.ClassId,
           e.SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.ClassName,
           c.Grade,
           c.Section,
           e.SchoolId,
           (SELECT COUNT(*)
              FROM dbo.Students AS st
             WHERE st.SchoolId = e.SchoolId
               AND st.ClassId  = e.ClassId
               AND st.IsActive = 1) AS StudentCount,
           (SELECT COUNT(*)
              FROM dbo.Results AS r
             WHERE r.SchoolId      = e.SchoolId
               AND r.ExaminationId = e.Id
               AND r.IsActive      = 1) AS ResultsEntered
    FROM dbo.Examinations AS e
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = e.SchoolId AND s.Id = e.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = e.SchoolId AND c.Id = e.ClassId
    WHERE e.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR e.ClassId = @ClassId)
      AND e.IsActive = 1
    ORDER BY e.ExamDate DESC;
END
GO

SET NOEXEC OFF;
GO
