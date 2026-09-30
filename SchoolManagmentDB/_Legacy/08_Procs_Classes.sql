/*==============================================================================
  08_Procs_Classes.sql  --  Class CRUD and class statistics.

  @ClassTeacherId IS A Teachers.Id in every procedure here. The old procedures
  validated it against Users (Role = 'Teacher') and joined it to Users for the
  display name, while sp_GetTeacherClasses read the same column expecting a
  Users.Id -- the two could not both be right.

  OverdueFees was:
      f.Id NOT IN (SELECT FeeId FROM FeePayments GROUP BY FeeId
                    HAVING SUM(AmountPaid) >= (SELECT Amount FROM Fees WHERE Id = FeeId))
  The correlated scalar subquery inside HAVING forces a per-group re-read of
  Fees, cannot use an index, and drops fees with no payment rows at all from the
  NOT IN set only by accident. Rewritten as a LEFT JOIN onto pre-aggregated
  payments.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  sp_CreateClass -- Returns: Result, ClassId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateClass
    @SchoolId       INT,
    @ClassName      NVARCHAR(50),
    @Grade          NVARCHAR(10),
    @Section        NVARCHAR(5),
    @MaxStudents    INT,
    @ClassTeacherId INT = NULL      -- Teachers.Id
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF @ClassTeacherId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Teachers
                            WHERE SchoolId = @SchoolId AND Id = @ClassTeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Invalid class teacher' AS Result, CAST(NULL AS INT) AS ClassId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND Grade = @Grade AND Section = @Section)
        BEGIN
            /* Not filtered on IsActive: UQ_Classes_School_GradeSection covers
               soft-deleted rows too, so the old "IsActive = 1" check let the
               insert through and then failed on the constraint. */
            SELECT 'Error: A class with this grade and section already exists' AS Result,
                   CAST(NULL AS INT) AS ClassId;
            RETURN;
        END

        INSERT INTO dbo.Classes (SchoolId, ClassName, Grade, Section, MaxStudents, ClassTeacherId)
        VALUES (@SchoolId, @ClassName, @Grade, @Section, @MaxStudents, @ClassTeacherId);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS ClassId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS ClassId;
    END CATCH
END
GO

/*==============================================================================
  sp_GetAllClasses -- Returns: the requested page, then the total row count.

  Took only @SchoolId while ClassRepository passed five parameters and read two
  result sets, so GET /api/Classes failed outright with "too many arguments
  specified". Filtering and paging were the API's documented contract
  (?grade=&isActive=&page=&pageSize=) and were simply never implemented here.

  @IsActive is a filter, not a fixed predicate: the list screen has an
  active/inactive/all toggle, and the old hardcoded IsActive = 1 made
  soft-deleted classes unreachable -- which matters because sp_CreateClass
  refuses a grade+section that a *deleted* class still occupies. Without a way
  to see them, that refusal is unexplainable.

  ClassTeacher and StudentCount were aliased to names ClassDTO does not have
  (it declares ClassTeacherName and TotalStudents), so both arrived empty. The
  same mistake was in sp_GetClassById.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllClasses
    @SchoolId   INT,
    @Grade      NVARCHAR(10) = NULL,
    @IsActive   BIT          = NULL,   -- NULL = both
    @Page       INT          = 1,
    @PageSize   INT          = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* Defensive, not decorative: page 0 would make OFFSET negative and raise. */
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 100 SET @PageSize = 100;   -- mirrors Constants.Settings.MaxPageSize

    /* Empty string treated as absent: a cleared filter box posts ?grade= rather
       than dropping the parameter, and matching on '' would return nothing. */
    IF @Grade = N'' SET @Grade = NULL;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           c.IsActive,
           c.CreatedAt,
           c.UpdatedAt,
           c.ClassTeacherId,
           CASE WHEN c.ClassTeacherId IS NOT NULL
                THEN u.FirstName + ' ' + u.LastName
                ELSE NULL END AS ClassTeacherName,
           COUNT(s.Id) AS TotalStudents,
           c.SchoolId
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = c.SchoolId AND t.Id = c.ClassTeacherId
    LEFT JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND (@Grade IS NULL OR c.Grade = @Grade)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents, c.IsActive,
             c.CreatedAt, c.UpdatedAt, c.ClassTeacherId, u.FirstName, u.LastName, c.SchoolId
    /* Grade is NVARCHAR, so '10' sorts before '2' as text. TRY_CONVERT first puts
       it in the order a person reads a class list in; the text key breaks ties for
       non-numeric grades such as 'KG', which convert to NULL. */
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Classes AS c
    WHERE c.SchoolId = @SchoolId
      AND (@Grade IS NULL OR c.Grade = @Grade)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive);
END
GO

/*==============================================================================
  sp_GetClassById

  ClassTeacher/StudentCount renamed to ClassTeacherName/TotalStudents to match
  ClassDTO, and UpdatedAt added -- without it the API returned 0001-01-01 for
  every class, which a client cannot tell from a real timestamp.

  ClassTeacherEmail and ClassTeacherPhone are not on ClassDTO and so go nowhere.
  Kept because this is also the single-class read for any future detail view, and
  dropping columns is the change that silently empties a screen later.

  @IncludeInactive exists for sp_GetClassDetails: a soft-deleted class must still
  be openable, or an administrator cannot see what is occupying a grade+section
  that sp_CreateClass keeps refusing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassById
    @SchoolId         INT,
    @ClassId          INT,
    @IncludeInactive  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           c.IsActive,
           c.CreatedAt,
           c.UpdatedAt,
           c.ClassTeacherId,
           CASE WHEN c.ClassTeacherId IS NOT NULL
                THEN CONCAT(u.FirstName, ' ', u.LastName)
                ELSE NULL END AS ClassTeacherName,
           u.Email AS ClassTeacherEmail,
           u.PhoneNumber AS ClassTeacherPhone,
           COUNT(s.Id) AS TotalStudents,
           c.SchoolId
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = c.SchoolId AND t.Id = c.ClassTeacherId
    LEFT JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND c.Id = @ClassId
      AND (@IncludeInactive = 1 OR c.IsActive = 1)
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents, c.IsActive, c.CreatedAt,
             c.UpdatedAt, c.ClassTeacherId, u.FirstName, u.LastName, u.Email, u.PhoneNumber,
             c.SchoolId;
END
GO

/*==============================================================================
  sp_UpdateClass -- Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateClass
    @SchoolId       INT,
    @ClassId        INT,
    @ClassName      NVARCHAR(50),
    @Grade          NVARCHAR(10),
    @Section        NVARCHAR(5),
    @MaxStudents    INT,
    @ClassTeacherId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Class not found' AS Result;
            RETURN;
        END

        IF @ClassTeacherId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Teachers
                            WHERE SchoolId = @SchoolId AND Id = @ClassTeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Invalid class teacher' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND Grade = @Grade AND Section = @Section
                      AND Id <> @ClassId)
        BEGIN
            SELECT 'Error: A class with this grade and section already exists' AS Result;
            RETURN;
        END

        /* Shrinking MaxStudents below the current head-count would make
           sp_RegisterStudent reject every future admission with "class is full"
           and leave the class over capacity with no explanation. */
        DECLARE @Enrolled INT = (SELECT COUNT(*) FROM dbo.Students
                                  WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1);

        IF @MaxStudents < @Enrolled
        BEGIN
            SELECT 'Error: Capacity cannot be less than the ' + CAST(@Enrolled AS NVARCHAR(10))
                 + ' students already enrolled' AS Result;
            RETURN;
        END

        UPDATE dbo.Classes
           SET ClassName      = @ClassName,
               Grade          = @Grade,
               Section        = @Section,
               MaxStudents    = @MaxStudents,
               ClassTeacherId = @ClassTeacherId,
               UpdatedAt      = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @ClassId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteClass -- soft delete, blocked by any dependent data.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteClass
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Class not found' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Students
                    WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete class with active students. Please move students to another class first.' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Attendance WHERE SchoolId = @SchoolId AND ClassId = @ClassId)
        BEGIN
            SELECT 'Error: Cannot delete class with attendance records. This class has historical data.' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Examinations
                    WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete class with examination records. Please remove examinations first.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Timetable and grade-entry rights must go too, otherwise the class
           disappears from the class list but still shows on teacher timetables. */
        UPDATE dbo.TeacherSchedule SET IsActive = 0
         WHERE SchoolId = @SchoolId AND ClassId = @ClassId;

        UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
         WHERE SchoolId = @SchoolId AND ClassId = @ClassId;

        UPDATE dbo.Classes SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ClassId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_GetClassStudents
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassStudents
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.AdmissionDate,
           u.Id AS UserId,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.FatherName,
           s.MotherName,
           s.BloodGroup
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

/*==============================================================================
  sp_GetClassStats

  Column names kept: TotalStudents, MaxStudents, PresentLast30Days,
  AbsentLast30Days, TotalExaminations, TotalFees, OverdueFees
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassStats
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Since DATE = CAST(DATEADD(DAY, -30, GETDATE()) AS DATE);
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) AS TotalStudents,

           (SELECT MaxStudents FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND Id = @ClassId) AS MaxStudents,

           (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1
               AND Gender = 'Male') AS MaleStudents,

           (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1
               AND Gender = 'Female') AS FemaleStudents,

           /* Of the marks actually taken in the window, not of the roll. NULL when
              the register has not been opened at all, because 0% there would read
              as a class that never attends. Two decimals: ClassStatsDTO carries
              this as a decimal, and rounding at the source keeps the API from
              reporting 87.333333333333. */
           (SELECT CASE WHEN COUNT(*) = 0 THEN NULL
                        ELSE ROUND(SUM(CASE WHEN a.IsPresent = 1 THEN 1.0 ELSE 0 END)
                                   * 100.0 / COUNT(*), 2)
                   END
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since) AS AverageAttendance,

           (SELECT COUNT(*)
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since AND a.IsPresent = 1) AS PresentLast30Days,

           (SELECT COUNT(*)
              FROM dbo.Attendance AS a
              INNER JOIN dbo.Students AS s ON s.SchoolId = a.SchoolId AND s.Id = a.StudentId
             WHERE a.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND a.AttendanceDate >= @Since AND a.IsPresent = 0) AS AbsentLast30Days,

           (SELECT COUNT(*) FROM dbo.Examinations
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) AS TotalExaminations,

           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              INNER JOIN dbo.Students AS s ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
             WHERE f.SchoolId = @SchoolId AND s.ClassId = @ClassId AND f.IsActive = 1) AS TotalFees,

           /* Past due and not yet covered by completed payments. */
           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              INNER JOIN dbo.Students AS s ON s.SchoolId = f.SchoolId AND s.Id = f.StudentId
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId AND s.ClassId = @ClassId
               AND f.IsActive = 1
               AND f.DueDate < @Today
               AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees;
END
GO

/*==============================================================================
  sp_UpdateClassStatus -- Returns: Result

  New. ClassRepository.UpdateClassStatusAsync has always called this, so
  PUT /api/Classes/{id}/status failed with "Could not find stored procedure".

  Suspending a class is not the same as deleting one, so the dependency checks in
  sp_DeleteClass deliberately do not apply: a class with students and a term of
  attendance behind it is exactly the kind you suspend rather than delete. What it
  does do is cascade to the timetable, the same way the delete does -- a suspended
  class must stop appearing on teachers' schedules, or the suspension is invisible
  where it matters most.

  Reactivation restores the class row only. Timetable and grade-entry rights are
  not brought back, because there is no record of which of them were already
  inactive before the suspension, and guessing would hand a teacher rights that
  had been withdrawn on purpose.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateClassStatus
    @SchoolId   INT,
    @ClassId    INT,
    @IsActive   BIT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @Current BIT;

        SELECT @Current = IsActive
        FROM dbo.Classes
        WHERE SchoolId = @SchoolId AND Id = @ClassId;

        IF @Current IS NULL
        BEGIN
            SELECT 'Error: Class not found' AS Result;
            RETURN;
        END

        /* Idempotent rather than an error: a double-clicked toggle, or two
           administrators reaching the same conclusion, is not a failure. */
        IF @Current = @IsActive
        BEGIN
            SELECT 'Success' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Classes
           SET IsActive = @IsActive, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ClassId;

        IF @IsActive = 0
        BEGIN
            UPDATE dbo.TeacherSchedule SET IsActive = 0
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId;
        END

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_GetClassDetails -- Returns three result sets: class, students, stats.

  New. ClassRepository.GetClassDetailsAsync has always called this and read three
  result sets from it, so GET /api/Classes/{id}/details failed with "Could not
  find stored procedure".

  One round trip instead of three, and -- more to the point -- one consistent
  read: with three separate calls the student list can change between the list and
  the count that is supposed to describe it.

  @IncludeInactive = 1 on the class read, because a details page is how you find
  out *why* a class is suspended. An empty first result set is the signal that the
  class does not exist; the repository returns null on it and the controller 404s.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassDetails
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_GetClassById  @SchoolId = @SchoolId, @ClassId = @ClassId, @IncludeInactive = 1;
    EXEC dbo.sp_GetClassStudents @SchoolId = @SchoolId, @ClassId = @ClassId;
    EXEC dbo.sp_GetClassStats @SchoolId = @SchoolId, @ClassId = @ClassId;
END
GO

PRINT '=== 08_Procs_Classes.sql complete ===';
GO

SET NOEXEC OFF;
GO
