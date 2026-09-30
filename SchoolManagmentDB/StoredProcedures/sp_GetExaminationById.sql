/*==============================================================================
  StoredProcedure : dbo.sp_GetExaminationById
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
  sp_GetExaminationById -- NEW.

  Not a convenience. ExaminationRepository.GetExaminationByIdAsync carried this
  query as an inline string with unqualified table names, which is the one thing
  Â§8 of FRONTEND_PLAN.md tells every later phase to grep for: a repository can
  match sys.parameters perfectly and still hold SQL that no migration touches.

  Two differences from the version it replaces, beyond having a name. It returns
  the same StudentCount/ResultsEntered pair as the list, so opening one exam and
  listing them all agree on the figures; and it is the only read here that is
  allowed to see a soft-deleted exam, through @IncludeInactive, because a mark
  sheet reached from a stale link should be able to say "this exam was deleted"
  rather than show an empty class.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetExaminationById
    @SchoolId           INT,
    @ExaminationId      INT,
    @IncludeInactive    BIT = 0
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
      AND e.Id       = @ExaminationId
      AND (@IncludeInactive = 1 OR e.IsActive = 1);
END
GO

SET NOEXEC OFF;
GO
