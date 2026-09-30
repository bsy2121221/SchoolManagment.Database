/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentResults
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
  sp_GetStudentResults -- every mark one student has been given, newest first.

  This is the report card, and unlike sp_GetExaminationResults it is driven from
  Results with INNER JOINs, so every row here is a real mark. There is no
  unmarked-student case and therefore none of that procedure's NULL trap: an
  examination the student has not been marked for simply does not appear.

  Percentage and IsPass are computed here rather than in the client because the
  report card groups by exam type and averages, and a client recomputing
  ObtainedMarks/MaxMarks per row would disagree with sp_GetExaminationResults's
  rounding on the same mark. SubjectId and ClassId are returned so the screen can
  group and filter without matching on display names.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentResults
    @SchoolId   INT,
    @StudentId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.Id,
           r.ObtainedMarks,
           r.Grade,
           r.Remarks,
           r.CreatedAt,
           r.UpdatedAt,
           e.Id AS ExaminationId,
           e.ExamName,
           e.ExamType,
           e.MaxMarks,
           e.PassingMarks,
           e.ExamDate,
           CAST(ROUND(100.0 * r.ObtainedMarks / NULLIF(e.MaxMarks, 0), 2) AS DECIMAL(5,2)) AS Percentage,
           CAST(CASE WHEN r.ObtainedMarks >= e.PassingMarks THEN 1 ELSE 0 END AS BIT) AS IsPass,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade AS ClassGrade,
           c.Section
    FROM dbo.Results AS r
    INNER JOIN dbo.Examinations AS e ON e.SchoolId = r.SchoolId AND e.Id = r.ExaminationId
    INNER JOIN dbo.Subjects     AS s ON s.SchoolId = e.SchoolId AND s.Id = e.SubjectId
    INNER JOIN dbo.Classes      AS c ON c.SchoolId = e.SchoolId AND c.Id = e.ClassId
    WHERE r.SchoolId = @SchoolId
      AND r.StudentId = @StudentId
      AND r.IsActive = 1
    ORDER BY e.ExamDate DESC;
END
GO

SET NOEXEC OFF;
GO
