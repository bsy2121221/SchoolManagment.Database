/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentProfile
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
  sp_GetStudentProfile -- FOUR result sets, keyed on either id.

  The class-teacher name used to be joined as
      LEFT JOIN Users ct ON c.ClassTeacherId = ct.Id
  which was only ever correct because ClassTeacherId happened to hold a user id.
  It now holds Teachers.Id, so the join goes through Teachers.

  WHAT CHANGED
    The repository has always passed @StudentId (Students.Id) and read four
    result sets -- student, academic stats, subjects, fee status. This procedure
    declared only @UserId and returned one, so GET /students/{id}/profile failed
    on the parameter before it could fail on the shape. It now accepts either
    key: pass @StudentId from the admin screens, or @UserId for a self-service
    profile, which is how the old signature was called.

  ALL FOUR SETS ARE ALWAYS EMITTED, even for a student who does not exist. A
  QueryMultiple reader that stops early leaves the caller reading a closed
  reader, and "no such student" is the first set being empty.

  AverageMarks IS A PERCENTAGE. AcademicStatsDTO does not say so, but a raw mark
  average across examinations with different MaxMarks is not a number anyone can
  use: 40/50 and 40/100 are not the same performance. Total obtained over total
  possible is. Grade comes from fn_CalculateGrade on the same two totals, so the
  grade and the number can never disagree.

  Rank is within the student's own class, counting only students who have at
  least one result. It is NULL when this student has none, or has no class.

  Extra columns on the first set (ClassDisplay, ClassTeacher, SchoolCode,
  SchoolName) are not on StudentDTO and Dapper ignores them, as with
  sp_GetClassById's teacher contact columns. Kept for the detail screen that
  will want them, because dropping columns is the change that silently empties a
  screen a year later.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentProfile
    @SchoolId   INT,
    @StudentId  INT = NULL,     -- Students.Id
    @UserId     INT = NULL      -- or the account id, for the self-service screen
AS
BEGIN
    SET NOCOUNT ON;

    /* One of the two identifies the row; @StudentId wins if both arrive. */
    IF @StudentId IS NULL AND @UserId IS NOT NULL
        SELECT @StudentId = Id FROM dbo.Students
         WHERE SchoolId = @SchoolId AND UserId = @UserId;

    DECLARE @ClassId INT = (SELECT ClassId FROM dbo.Students
                             WHERE SchoolId = @SchoolId AND Id = @StudentId);

    /* ---- 1. the student ---------------------------------------------------*/
    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           s.IsActive,
           /* The student record's own timestamps, not the account's: an edit to
              the profile stamps Students, and StudentDTO's UpdatedAt is what the
              screen shows as "last changed". */
           s.CreatedAt,
           s.UpdatedAt,

           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,

           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           CONCAT(c.Grade, c.Section) AS ClassDisplay,

           CONCAT(ctu.FirstName, ' ', ctu.LastName) AS ClassTeacher,

           s.SchoolId,
           sch.SchoolCode,
           sch.SchoolName
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN dbo.Teachers AS ct ON ct.SchoolId = c.SchoolId AND ct.Id = c.ClassTeacherId
    LEFT JOIN dbo.vw_Users AS ctu ON ctu.SchoolId = ct.SchoolId AND ctu.Id = ct.UserId
    LEFT JOIN dbo.Schools AS sch ON sch.Id = s.SchoolId
    /* No IsActive filter: a profile has to stay readable after the student
       leaves, which is the whole point of the delete being a soft one. */
    WHERE s.SchoolId = @SchoolId
      AND s.Id = @StudentId;

    /* ---- 2. academic stats ------------------------------------------------*/
    DECLARE @Obtained DECIMAL(18,4), @Possible DECIMAL(18,4);

    SELECT @Obtained = SUM(CAST(r.ObtainedMarks AS DECIMAL(18,4))),
           @Possible = SUM(CAST(e.MaxMarks AS DECIMAL(18,4)))
    FROM dbo.Results AS r
    INNER JOIN dbo.Examinations AS e ON e.SchoolId = r.SchoolId AND e.Id = r.ExaminationId
    WHERE r.SchoolId = @SchoolId
      AND r.StudentId = @StudentId
      AND r.IsActive = 1;

    DECLARE @Percent DECIMAL(9,2) =
        CASE WHEN ISNULL(@Possible, 0) > 0
             THEN CAST(@Obtained * 100.0 / @Possible AS DECIMAL(9,2)) END;

    DECLARE @Rank INT = NULL;

    IF @Percent IS NOT NULL AND @ClassId IS NOT NULL
    BEGIN
        /* Competition ranking: two students on the same percentage share a
           place, and the next one down is pushed past both. */
        /* Leading semicolon because a CTE has to be the first statement of its
           own; BEGIN does not count as a terminator everywhere. */
        ;WITH Scored AS (
            SELECT r.StudentId,
                   SUM(CAST(r.ObtainedMarks AS DECIMAL(18,4))) * 100.0
                     / NULLIF(SUM(CAST(e.MaxMarks AS DECIMAL(18,4))), 0) AS Pct
            FROM dbo.Results AS r
            INNER JOIN dbo.Examinations AS e ON e.SchoolId = r.SchoolId AND e.Id = r.ExaminationId
            INNER JOIN dbo.Students AS peer ON peer.SchoolId = r.SchoolId AND peer.Id = r.StudentId
            WHERE r.SchoolId = @SchoolId
              AND r.IsActive = 1
              AND peer.ClassId = @ClassId
              AND peer.IsActive = 1
            GROUP BY r.StudentId
        )
        SELECT @Rank = COUNT(*) + 1 FROM Scored WHERE Pct > @Percent;
    END

    DECLARE @Present INT, @Marked INT;

    SELECT @Marked  = COUNT(*),
           @Present = SUM(CASE WHEN IsPresent = 1 THEN 1 ELSE 0 END)
    FROM dbo.Attendance
    WHERE SchoolId = @SchoolId AND StudentId = @StudentId;

    SELECT (SELECT COUNT(*) FROM dbo.StudentSubjects
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalSubjects,
           @Percent AS AverageMarks,
           dbo.fn_CalculateGrade(@SchoolId, @Obtained, @Possible) AS Grade,
           @Rank AS [Rank],
           /* Nobody marked yet reads as 0%, not as 100%: an empty register says
              nothing about attendance, and rounding it up flatters the student. */
           CASE WHEN ISNULL(@Marked, 0) > 0
                THEN CAST(@Present * 100.0 / @Marked AS DECIMAL(5,2))
                ELSE CAST(0 AS DECIMAL(5,2)) END AS AttendancePercentage;

    /* ---- 3. the subjects taken -------------------------------------------*/
    SELECT sub.Id,
           sub.SubjectName,
           sub.SubjectCode
    FROM dbo.StudentSubjects AS ss
    INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
    WHERE ss.SchoolId = @SchoolId
      AND ss.StudentId = @StudentId
      AND ss.IsActive = 1
    ORDER BY sub.SubjectName;

    /* ---- 4. fee status ----------------------------------------------------*/
    SELECT ISNULL(SUM(f.Amount), 0) AS TotalDue,
           ISNULL(SUM(ISNULL(p.Paid, 0)), 0) AS TotalPaid,
           /* Summed per fee and floored at zero, so an overpayment on one fee
              cannot quietly cancel out what is still owed on another. */
           ISNULL(SUM(CASE WHEN f.Amount - ISNULL(p.Paid, 0) > 0
                           THEN f.Amount - ISNULL(p.Paid, 0) ELSE 0 END), 0) AS PendingFees
    FROM dbo.Fees AS f
    LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                 FROM dbo.FeePayments
                WHERE PaymentStatus = 'Completed'
                GROUP BY SchoolId, FeeId) AS p
           ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
    WHERE f.SchoolId = @SchoolId
      AND f.StudentId = @StudentId
      AND f.IsActive = 1;
END
GO

SET NOEXEC OFF;
GO
