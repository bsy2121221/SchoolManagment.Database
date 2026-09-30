/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentsForGradeEntry
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
  sp_GetStudentsForGradeEntry

  @TeacherId is Teachers.Id. The authorisation check reads
  TeacherSubjectAssignments, which now stores Teachers.Id -- before, that table
  held Users.Id, so this check compared the wrong kind of number and either let
  the wrong teacher through or blocked the right one.

  @ExaminationId is a new optional parameter. Without it the old version joined
  Examinations on class+subject with no date filter, so a class with two exams in
  the same subject returned each student twice and the entry screen showed
  duplicate rows. Passing an id pins it to one exam; omitting it picks the most
  recent.

  Three further repairs, all of which the grade-entry screen depends on:

  @IsAdmin is new. TeacherSubjectAssignments is the right check for a teacher and
  the wrong one for an administrator, who has no rows in it -- so an admin could
  not open the only screen the API provides for entering a class's marks, even
  though POST /api/Results/bulk accepts their submission. An admin now bypasses
  the assignment check; a teacher is still held to it.

  CurrentMarks was COALESCE(r.ObtainedMarks, 0), which made a student nobody has
  marked indistinguishable from one who scored zero. On an *entry* grid that is
  worse than on a report: every unmarked row arrives pre-filled with 0, and a
  teacher who saves the screen after marking half the class writes zeros for the
  other half. It is now the raw nullable mark, with HasResult saying whether a row
  exists at all. CurrentGrade and CurrentRemarks are likewise no longer coalesced
  to ''.

  A NULL @ExaminationId used to fall through to COALESCE(e.MaxMarks, 100) and
  COALESCE(e.PassingMarks, 40), so a class+subject with no examination at all
  returned a full roll marked out of a fabricated 100 against ExaminationId NULL.
  Every submission from that screen would then be rejected. It now returns no rows.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsForGradeEntry
    @SchoolId       INT,
    @TeacherId      INT,
    @SubjectId      INT,
    @ClassId        INT,
    @ExaminationId  INT = NULL,
    @IsAdmin        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @IsAdmin = 0
       AND NOT EXISTS (SELECT 1 FROM dbo.TeacherSubjectAssignments
                        WHERE SchoolId = @SchoolId
                          AND TeacherId = @TeacherId
                          AND SubjectId = @SubjectId
                          AND ClassId = @ClassId
                          AND IsActive = 1)
    BEGIN
        RAISERROR('Teacher is not authorized to enter grades for this subject/class', 16, 1);
        RETURN;
    END

    /* Resolve exactly one examination up front instead of joining to all of
       them. */
    IF @ExaminationId IS NULL
        SELECT @ExaminationId = (SELECT TOP 1 Id
                                   FROM dbo.Examinations
                                  WHERE SchoolId = @SchoolId
                                    AND ClassId = @ClassId
                                    AND SubjectId = @SubjectId
                                    AND IsActive = 1
                                  ORDER BY ExamDate DESC, Id DESC);

    /* No examination means there is nothing to enter marks against. Returning the
       roll anyway, against invented marks, is worse than returning nothing. */
    IF NOT EXISTS (SELECT 1 FROM dbo.Examinations
                    WHERE SchoolId = @SchoolId AND Id = @ExaminationId
                      AND ClassId = @ClassId AND SubjectId = @SubjectId
                      AND IsActive = 1)
        RETURN;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           u.Email,
           c.ClassName,
           c.Grade AS ClassGrade,
           c.Section,
           subj.SubjectName,
           subj.SubjectCode,
           r.ObtainedMarks AS CurrentMarks,
           r.Grade AS CurrentGrade,
           r.Remarks AS CurrentRemarks,
           CAST(CASE WHEN r.Id IS NULL THEN 0 ELSE 1 END AS BIT) AS HasResult,
           e.MaxMarks,
           e.PassingMarks,
           e.Id AS ExaminationId,
           e.ExamName,
           e.ExamType,
           e.ExamDate
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    INNER JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    INNER JOIN dbo.Subjects AS subj ON subj.SchoolId = s.SchoolId AND subj.Id = @SubjectId
    /* INNER, not LEFT: the guard above proved this examination exists, and an INNER
       join is what makes MaxMarks and PassingMarks provably non-NULL for the DTO. */
    INNER JOIN dbo.Examinations AS e
           ON e.SchoolId = s.SchoolId AND e.Id = @ExaminationId
    LEFT JOIN dbo.Results AS r
           ON r.SchoolId = s.SchoolId
          AND r.StudentId = s.Id
          AND r.ExaminationId = e.Id
          AND r.IsActive = 1
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
      AND c.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber, u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
