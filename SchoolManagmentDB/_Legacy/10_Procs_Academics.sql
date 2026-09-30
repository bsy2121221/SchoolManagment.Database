/*==============================================================================
  10_Procs_Academics.sql  --  Subjects, examinations, results, grade entry.

  NEW: sp_CreateSubject / sp_UpdateSubject / sp_DeleteSubject.
  There was no way to create a subject at all -- the only rows in Subjects came
  from INSERT statements embedded in setup scripts. A newly onboarded school
  would have had none and no way to add any. (sp_CreateSchool seeds a starter
  list; these let a school manage it afterwards.)

  NEW: sp_GetAllSubjects / sp_GetSubjectById / sp_UpdateSubjectStatus.
  SubjectRepository has always called all three by these names, so GET
  /api/Subjects, GET /api/Subjects/{id} and PUT /api/Subjects/{id}/status each
  failed with "Could not find stored procedure". The reads are shaped to
  SubjectDTO -- CreatedAt and UpdatedAt included, which sp_GetSubjects omitted,
  so the API used to return 0001-01-01 for both on every subject it did return.

  FIXES
    * sp_BulkGradeEntry made two passes over the same JSON (an INSERT for new
      students, then an UPDATE for existing ones) and validated nothing. Marks
      could be posted for a student who was not in the examination's class, or
      above MaxMarks. It is now one MERGE against a validated set.
    * sp_AddOrUpdateResult used IF EXISTS / UPDATE / ELSE INSERT, which can
      double-insert under concurrency. Now a MERGE ... WITH (HOLDLOCK).
    * @Grade is optional everywhere now: when the API does not supply one,
      dbo.fn_CalculateGrade fills it from that school's own grading scale.
      Existing callers that pass a grade are unaffected.
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
  ---------------------------------- SUBJECTS ----------------------------------
==============================================================================*/

/*==============================================================================
  sp_GetSubjects

  The unpaged, active-only list. This is what SubjectRepository's
  GetSubjectsByGradeAsync now calls -- it was asking for sp_GetSubjectsByGrade,
  which does not exist, when a procedure taking exactly (@SchoolId, @Grade) and
  returning exactly that grade's live subjects was already deployed.

  CreatedAt and UpdatedAt added: both are on SubjectDTO, and a column the
  procedure does not select comes back as 0001-01-01, which a client cannot tell
  from a real timestamp. One result set and the same row count as before, so
  16_Verify.sql's @@ROWCOUNT assertion still holds.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSubjects
    @SchoolId   INT,
    @Grade      NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* A cleared filter box posts ?grade= rather than dropping the parameter, and
       matching on '' would return nothing. */
    IF @Grade = N'' SET @Grade = NULL;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive, CreatedAt, UpdatedAt, SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND IsActive = 1
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName;
END
GO

/*==============================================================================
  sp_GetAllSubjects -- NEW. Returns two result sets: the page, then TotalCount.

  The paged read behind GET /api/Subjects, shaped like sp_GetAllClasses because
  the repository, service and controller treat the two the same way.

  Unlike sp_GetSubjects this does not hardcode IsActive = 1: an administrator
  managing the subject list has to be able to see the deactivated ones, or a code
  held by a soft-deleted subject looks like sp_CreateSubject refusing for no
  reason.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSubjects
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

    IF @Grade = N'' SET @Grade = NULL;

    SELECT Id,
           SubjectName,
           SubjectCode,
           Grade,
           IsActive,
           CreatedAt,
           UpdatedAt,
           SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND (@IsActive IS NULL OR IsActive = @IsActive)
    /* Grade is NVARCHAR, so '10' sorts before '2' as text. TRY_CONVERT first puts
       it in the order a person reads the list in; the text key breaks ties for
       non-numeric grades such as 'KG', which convert to NULL. */
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND (@IsActive IS NULL OR IsActive = @IsActive);
END
GO

/*==============================================================================
  sp_GetSubjectById -- NEW.

  @IncludeInactive defaults to 1, the opposite of sp_GetClassById. This is the
  read behind the edit and status screens, and the list they are opened from can
  show deactivated subjects: 404ing on a row the user just clicked would be a
  bug, and reactivating one would be impossible.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSubjectById
    @SchoolId         INT,
    @SubjectId        INT,
    @IncludeInactive  BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive, CreatedAt, UpdatedAt, SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND Id = @SubjectId
      AND (@IncludeInactive = 1 OR IsActive = 1);
END
GO

/*==============================================================================
  sp_CreateSubject -- NEW. Returns: Result, SubjectId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateSubject
    @SchoolId       INT,
    @SubjectName    NVARCHAR(100),
    @SubjectCode    NVARCHAR(20),
    @Grade          NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        SET @SubjectCode = UPPER(LTRIM(RTRIM(ISNULL(@SubjectCode, N''))));

        IF @SubjectCode = N''
        BEGIN
            SELECT 'Error: Subject code is required' AS Result, CAST(NULL AS INT) AS SubjectId;
            RETURN;
        END

        /* Codes are unique per school, not globally -- two schools may both use
           'MATH10'. Soft-deleted rows still hold the code, so a re-created
           subject is reactivated rather than duplicated. */
        DECLARE @Existing INT = (SELECT Id FROM dbo.Subjects
                                  WHERE SchoolId = @SchoolId AND SubjectCode = @SubjectCode);

        IF @Existing IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.Subjects WHERE Id = @Existing AND IsActive = 1)
            BEGIN
                SELECT 'Error: A subject with this code already exists' AS Result,
                       CAST(NULL AS INT) AS SubjectId;
                RETURN;
            END

            UPDATE dbo.Subjects
               SET SubjectName = @SubjectName,
                   Grade       = @Grade,
                   IsActive    = 1,
                   UpdatedAt   = GETDATE()
             WHERE Id = @Existing;

            SELECT 'Success' AS Result, @Existing AS SubjectId;
            RETURN;
        END

        INSERT INTO dbo.Subjects (SchoolId, SubjectName, SubjectCode, Grade)
        VALUES (@SchoolId, @SubjectName, @SubjectCode, @Grade);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS SubjectId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS SubjectId;
    END CATCH
END
GO

/*==============================================================================
  sp_UpdateSubject -- NEW. Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSubject
    @SchoolId       INT,
    @SubjectId      INT,
    @SubjectName    NVARCHAR(100),
    @SubjectCode    NVARCHAR(20),
    @Grade          NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result;
            RETURN;
        END

        SET @SubjectCode = UPPER(LTRIM(RTRIM(ISNULL(@SubjectCode, N''))));

        IF EXISTS (SELECT 1 FROM dbo.Subjects
                    WHERE SchoolId = @SchoolId AND SubjectCode = @SubjectCode AND Id <> @SubjectId)
        BEGIN
            SELECT 'Error: A subject with this code already exists' AS Result;
            RETURN;
        END

        UPDATE dbo.Subjects
           SET SubjectName = @SubjectName,
               SubjectCode = @SubjectCode,
               Grade       = @Grade,
               UpdatedAt   = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @SubjectId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_UpdateSubjectStatus -- NEW. Returns: Result

  Deactivating pulls the subject off the timetable, because a period pointing at
  a subject nobody teaches any more is what produces an unexplainable clash later.
  It deliberately does *not* touch StudentSubjects or TeacherSubjects: those
  record who studies and who is qualified to teach the subject, and a term's
  suspension should not throw that away.

  Reactivating restores the subject alone. Schedule rows switched off here -- or
  cascaded off by sp_DeleteSubject, which is the same IsActive = 0 state -- stay
  off, and the timetable has to be rebuilt deliberately. Restoring them blindly
  would resurrect periods for teachers who have since been given other classes.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSubjectStatus
    @SchoolId   INT,
    @SubjectId  INT,
    @IsActive   BIT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @Current BIT;

        SELECT @Current = IsActive
        FROM dbo.Subjects
        WHERE SchoolId = @SchoolId AND Id = @SubjectId;

        IF @Current IS NULL
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result;
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

        UPDATE dbo.Subjects
           SET IsActive = @IsActive, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @SubjectId;

        IF @IsActive = 0
        BEGIN
            UPDATE dbo.TeacherSchedule SET IsActive = 0
             WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;
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
  sp_DeleteSubject -- NEW. Soft delete, blocked by examination history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteSubject
    @SchoolId   INT,
    @SubjectId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Examinations
                    WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete a subject with active examinations. Remove the examinations first.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.TeacherSchedule SET IsActive = 0
         WHERE SchoolId = @SchoolId AND SubjectId = @SubjectId;

        UPDATE dbo.Subjects SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @SubjectId;

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
  -------------------------------- EXAMINATIONS --------------------------------
==============================================================================*/

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

/*==============================================================================
  sp_GetExaminationById -- NEW.

  Not a convenience. ExaminationRepository.GetExaminationByIdAsync carried this
  query as an inline string with unqualified table names, which is the one thing
  §8 of FRONTEND_PLAN.md tells every later phase to grep for: a repository can
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

/*==============================================================================
  sp_CreateOrUpdateExamination

  Returns: ExaminationId, Result, Operation

  The match key is (ExamName, ExamType, ClassId, SubjectId) -- not the Id, which
  this procedure never takes. Two consequences the UI has to be built around,
  because neither is discoverable from the endpoint:

    * The four key fields cannot be changed. Sending the same exam with a new
      name creates a second exam and leaves the first one standing; the marks
      stay on the original.
    * Only ExamDate, MaxMarks, PassingMarks and Duration are ever updated.

  Operation is new, and it exists because the caller could not tell a create from
  an update. ExaminationsController used to answer that by re-reading the exam
  afterwards and returning 201 when the read came back empty -- so 201 Created
  fired only when the row it had just written could not be found, i.e. only on
  breakage, and a genuine create reported 200. The procedure is the only place
  that knows which branch ran, so it now says so.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateOrUpdateExamination
    @SchoolId       INT,
    @ExamName       NVARCHAR(100),
    @ExamType       NVARCHAR(50),
    @ClassId        INT,
    @SubjectId      INT,
    @ExamDate       DATE,
    @MaxMarks       INT,
    @PassingMarks   INT,
    @Duration       INT = NULL,
    @CreatedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Class not found in this school' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Subject not found in this school' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        IF @MaxMarks IS NULL OR @MaxMarks <= 0 OR @PassingMarks < 0 OR @PassingMarks > @MaxMarks
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Passing marks must be between 0 and max marks' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        DECLARE @ExaminationId INT = (SELECT Id FROM dbo.Examinations
                                       WHERE SchoolId = @SchoolId
                                         AND ExamName = @ExamName
                                         AND ExamType = @ExamType
                                         AND ClassId = @ClassId
                                         AND SubjectId = @SubjectId
                                         AND IsActive = 1);

        DECLARE @Operation NVARCHAR(10);

        IF @ExaminationId IS NOT NULL
        BEGIN
            /* Lowering MaxMarks under an already-entered score would leave marks
               that no longer make sense on the report card. */
            IF EXISTS (SELECT 1 FROM dbo.Results
                        WHERE SchoolId = @SchoolId AND ExaminationId = @ExaminationId
                          AND IsActive = 1 AND ObtainedMarks > @MaxMarks)
            BEGIN
                SELECT @ExaminationId AS ExaminationId,
                       'Error: Some entered marks exceed the new maximum' AS Result,
                       CAST(NULL AS NVARCHAR(10)) AS Operation;
                RETURN;
            END

            UPDATE dbo.Examinations
               SET ExamDate     = @ExamDate,
                   MaxMarks     = @MaxMarks,
                   PassingMarks = @PassingMarks,
                   Duration     = @Duration,
                   UpdatedAt    = GETDATE()
             WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

            SET @Operation = 'Updated';

            /* The create branch logged and this one did not, so rescheduling an
               exam or moving its pass mark left no trace at all. */
            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @CreatedBy,
                @Action = 'Examination.Update', @EntityType = 'Examination',
                @EntityId = @ExaminationId, @Details = @ExamName;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.Examinations (SchoolId, ExamName, ExamType, ClassId, SubjectId,
                                          ExamDate, MaxMarks, PassingMarks, Duration)
            VALUES (@SchoolId, @ExamName, @ExamType, @ClassId, @SubjectId,
                    @ExamDate, @MaxMarks, @PassingMarks, @Duration);

            SET @ExaminationId = CAST(SCOPE_IDENTITY() AS INT);
            SET @Operation = 'Created';

            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @CreatedBy,
                @Action = 'Examination.Create', @EntityType = 'Examination',
                @EntityId = @ExaminationId, @Details = @ExamName;
        END

        SELECT @ExaminationId AS ExaminationId, 'Success' AS Result, @Operation AS Operation;
    END TRY
    BEGIN CATCH
        SELECT 0 AS ExaminationId, 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS NVARCHAR(10)) AS Operation;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteExamination -- soft delete; the results go with it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteExamination
    @SchoolId       INT,
    @ExaminationId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Examinations
                        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Deactivating the results too keeps sp_GetStudentResults from showing
           marks for an exam that no longer appears in any list. */
        UPDATE dbo.Results SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND ExaminationId = @ExaminationId;

        UPDATE dbo.Examinations SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

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
  ----------------------------------- RESULTS -----------------------------------
==============================================================================*/

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

/*==============================================================================
  sp_AddOrUpdateResult

  @Grade is now optional: NULL means "work it out from this school's scale".

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AddOrUpdateResult
    @SchoolId       INT,
    @StudentId      INT,
    @ExaminationId  INT,
    @ObtainedMarks  INT,
    @Grade          NVARCHAR(5) = NULL,
    @Remarks        NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @ExamClassId INT, @MaxMarks INT;

        SELECT @ExamClassId = ClassId, @MaxMarks = MaxMarks
        FROM dbo.Examinations
        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1;

        IF @ExamClassId IS NULL
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result;
            RETURN;
        END

        /* The student must sit in the class the exam was set for. Nothing
           enforced this before, so a typo posted marks to another class. */
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId
                          AND ClassId = @ExamClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Student is not in the class this examination belongs to' AS Result;
            RETURN;
        END

        IF @ObtainedMarks < 0 OR @ObtainedMarks > @MaxMarks
        BEGIN
            SELECT 'Error: Marks must be between 0 and ' + CAST(@MaxMarks AS NVARCHAR(10)) AS Result;
            RETURN;
        END

        DECLARE @FinalGrade NVARCHAR(5) =
            COALESCE(NULLIF(@Grade, N''), dbo.fn_CalculateGrade(@SchoolId, @ObtainedMarks, @MaxMarks));

        MERGE dbo.Results WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId,
                      @ExaminationId AS ExaminationId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ExaminationId = src.ExaminationId
        WHEN MATCHED THEN
            UPDATE SET ObtainedMarks = @ObtainedMarks,
                       Grade         = @FinalGrade,
                       Remarks       = @Remarks,
                       IsActive      = 1,
                       UpdatedAt     = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ExaminationId, ObtainedMarks, Grade, Remarks)
            VALUES (src.SchoolId, src.StudentId, src.ExaminationId,
                    @ObtainedMarks, @FinalGrade, @Remarks);

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_BulkGradeEntry

  @GradeEntries: [{"StudentId":12,"ObtainedMarks":78,"Grade":"B","Remarks":""}, ...]
  Grade may be omitted or empty; it is then derived from the school's scale.

  Entries whose student is not in the examination's class, or whose marks fall
  outside 0..MaxMarks, are skipped and counted rather than aborting the batch --
  one bad row should not lose a teacher's whole entry screen.

  Two counting defects fixed. @Requested used to be taken *after* the
  StudentId/ObtainedMarks NULL filter, so an entry with a missing mark was
  neither saved nor reported as skipped -- it disappeared, and the caller was
  told Success. It is now taken from the raw OPENJSON row count, so
  EntriesSaved + EntriesSkipped always equals what was sent.

  And @In was declared with StudentId as a PRIMARY KEY, so a payload naming the
  same student twice raised a duplicate-key error that the CATCH turned into
  'Error: Violation of PRIMARY KEY ...' and lost the entire batch over one
  repeated row. Duplicates are now collapsed to their last occurrence, which is
  what a MERGE on the same key would have done anyway.

  Returns: Result, EntriesSaved, EntriesSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_BulkGradeEntry
    @SchoolId       INT,
    @ExaminationId  INT,
    @GradeEntries   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF ISJSON(ISNULL(@GradeEntries, N'')) <> 1
        BEGIN
            SELECT 'Error: GradeEntries is not valid JSON' AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
            RETURN;
        END

        DECLARE @ExamClassId INT, @MaxMarks INT;

        SELECT @ExamClassId = ClassId, @MaxMarks = MaxMarks
        FROM dbo.Examinations
        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1;

        IF @ExamClassId IS NULL
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
            RETURN;
        END

        /* Raw first, so nothing can be dropped without being counted. */
        DECLARE @Raw TABLE (Ordinal INT, StudentId INT, ObtainedMarks INT,
                            Grade NVARCHAR(5), Remarks NVARCHAR(255));

        INSERT INTO @Raw (Ordinal, StudentId, ObtainedMarks, Grade, Remarks)
        SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
               j.StudentId, j.ObtainedMarks, j.Grade, j.Remarks
        FROM OPENJSON(@GradeEntries)
             WITH (StudentId     INT           '$.StudentId',
                   ObtainedMarks INT           '$.ObtainedMarks',
                   Grade         NVARCHAR(5)   '$.Grade',
                   Remarks       NVARCHAR(255) '$.Remarks') AS j;

        DECLARE @Requested INT = (SELECT COUNT(*) FROM @Raw);

        DECLARE @In TABLE (StudentId INT PRIMARY KEY, ObtainedMarks INT,
                           Grade NVARCHAR(5), Remarks NVARCHAR(255));

        /* Last occurrence wins for a repeated StudentId, matching what a MERGE on
           the same key would settle on, instead of erroring on the PK. */
        INSERT INTO @In (StudentId, ObtainedMarks, Grade, Remarks)
        SELECT d.StudentId, d.ObtainedMarks, d.Grade, d.Remarks
        FROM (SELECT r.*,
                     ROW_NUMBER() OVER (PARTITION BY r.StudentId
                                            ORDER BY r.Ordinal DESC) AS Recency
                FROM @Raw AS r
               WHERE r.StudentId IS NOT NULL
                 AND r.ObtainedMarks IS NOT NULL) AS d
        WHERE d.Recency = 1;

        DECLARE @Valid TABLE (StudentId INT PRIMARY KEY, ObtainedMarks INT,
                              Grade NVARCHAR(5), Remarks NVARCHAR(255));

        INSERT INTO @Valid (StudentId, ObtainedMarks, Grade, Remarks)
        SELECT i.StudentId,
               i.ObtainedMarks,
               COALESCE(NULLIF(i.Grade, N''), dbo.fn_CalculateGrade(@SchoolId, i.ObtainedMarks, @MaxMarks)),
               i.Remarks
        FROM @In AS i
        INNER JOIN dbo.Students AS s
                ON s.SchoolId = @SchoolId AND s.Id = i.StudentId
               AND s.ClassId = @ExamClassId AND s.IsActive = 1
        WHERE i.ObtainedMarks BETWEEN 0 AND @MaxMarks;

        BEGIN TRANSACTION;

        MERGE dbo.Results WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, StudentId, @ExaminationId AS ExaminationId,
                      ObtainedMarks, Grade, Remarks
                 FROM @Valid) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ExaminationId = src.ExaminationId
        WHEN MATCHED THEN
            UPDATE SET ObtainedMarks = src.ObtainedMarks,
                       Grade         = src.Grade,
                       Remarks       = src.Remarks,
                       IsActive      = 1,
                       UpdatedAt     = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ExaminationId, ObtainedMarks, Grade, Remarks)
            VALUES (src.SchoolId, src.StudentId, src.ExaminationId,
                    src.ObtainedMarks, src.Grade, src.Remarks);

        DECLARE @Saved INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @Saved AS EntriesSaved,
               @Requested - @Saved AS EntriesSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
    END CATCH
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

/*==============================================================================
  sp_GetExaminationResults -- NEW. The whole mark sheet for one examination,
  with class rank. Useful for the results screen and printing.

  Returns: StudentId, StudentNumber, RollNumber, FirstName, LastName,
           ObtainedMarks, MaxMarks, PassingMarks, Percentage, Grade, IsPass,
           Remarks, ClassRank
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetExaminationResults
    @SchoolId       INT,
    @ExaminationId  INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ClassId INT, @MaxMarks INT, @PassingMarks INT;

    SELECT @ClassId = ClassId, @MaxMarks = MaxMarks, @PassingMarks = PassingMarks
    FROM dbo.Examinations
    WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           r.ObtainedMarks,
           @MaxMarks AS MaxMarks,
           @PassingMarks AS PassingMarks,
           CAST(ROUND(100.0 * r.ObtainedMarks / NULLIF(@MaxMarks, 0), 2) AS DECIMAL(5,2)) AS Percentage,
           r.Grade,
           CASE WHEN r.ObtainedMarks >= @PassingMarks THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPass,
           r.Remarks,
           /* Unmarked students rank last rather than first, which is what a plain
              ORDER BY on a NULL score would do. */
           RANK() OVER (ORDER BY CASE WHEN r.ObtainedMarks IS NULL THEN 1 ELSE 0 END,
                                 r.ObtainedMarks DESC) AS ClassRank
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Results AS r
           ON r.SchoolId = s.SchoolId
          AND r.StudentId = s.Id
          AND r.ExaminationId = @ExaminationId
          AND r.IsActive = 1
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY ClassRank, TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

PRINT '=== 10_Procs_Academics.sql complete ===';
GO

SET NOEXEC OFF;
GO
