/*==============================================================================
  06_Procs_Students.sql  --  Student registration, profile, subjects, listings.

  FIXES IN THIS FILE
    * Roll numbers and admission numbers came from
          (SELECT COUNT(*) + 1 FROM Students WHERE ClassId = @ClassId)
      which gave two concurrent registrations the same number and re-used a
      number after a delete. They now come from sp_NextSequence.
    * sp_AssignSubjectsToStudent parsed its input into a temp table, wrote
      nothing, and returned 'Success'. It writes to StudentSubjects now.
    * sp_AssignFeesToStudent was an empty stub returning 'Success'. It creates
      real Fees rows from a JSON array now.
    * sp_GetStudentProfileStats read a StudentFees table (with an IsPaid column)
      that has never existed in this database. Rewritten against Fees +
      FeePayments.
    * sp_GetStudentProfile joined the class teacher through Users, but
      Classes.ClassTeacherId now holds Teachers.Id.

  NEW IN THIS PASS: sp_GetAllStudents / sp_GetStudentById / sp_GetStudentsByClass
                    sp_UpdateStudent / sp_PromoteStudent / sp_RemoveStudentSubject
    StudentRepository calls all six by name and none of them existed, so six of
    the eleven /api/Students endpoints -- the list, the single read, the roster,
    edit, promote and unassign-subject -- failed with "Could not find stored
    procedure". The closest deployed siblings could not simply be renamed:
      - sp_GetStudentsWithDetails is unpaged, hardcodes IsActive = 1, and the
        repository reads a second result set with the total.
      - sp_GetStudentsForClass returns a narrow shape with no IsActive and no
        AdmissionDate, which Dapper would have filled with false and 0001-01-01.
      - sp_UpdateStudentProfile is keyed on @UserId (it is the self-service
        screen) and cannot set Gender.
    They are all still here and unchanged; the new procedures sit alongside them.

  ALSO FIXED
    * sp_GetStudentProfile took @UserId and returned one result set. The
      repository passes @StudentId and reads four (student, academic stats,
      subjects, fee status), so every profile read raised "@StudentId is not a
      parameter". It now takes either key and returns all four.
    * sp_RegisterStudent did not return ClassName, which
      StudentRegistrationResponseDTO declares -- and its Result column was never
      read at all, so a refusal ("Class 10A is full") was reported as a created
      student. Both are fixed here and in StudentRepository.
    * sp_GetStudentSubjects selected StudentSubjects.Id as the first Id column,
      so SubjectDTO.Id arrived holding the link row's id rather than the
      subject's -- and DELETE /students/{id}/subjects/{subjectId} then removed
      nothing. The subject's id is Id now; the link is StudentSubjectId.
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
  sp_RegisterStudent

  Returns: Result, UserId, StudentRecordId, Username, StudentId, RollNumber,
           ClassName (the first six are the original column names; ClassName is
           new, because StudentRegistrationResponseDTO declares it)

  The default password is the shared Temp@123 hash with
  RequirePasswordChange = 1, exactly as before -- the account cannot be used
  until the student sets their own password.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RegisterStudent
    @SchoolId           INT,
    @FirstName          NVARCHAR(50),
    @LastName           NVARCHAR(50),
    @Email              NVARCHAR(100),
    @PhoneNumber        NVARCHAR(15) = NULL,
    @Address            NVARCHAR(255) = NULL,
    @ClassId            INT = NULL,
    @DateOfBirth        DATE = NULL,
    @Gender             NVARCHAR(10) = NULL,
    @FatherName         NVARCHAR(100) = NULL,
    @MotherName         NVARCHAR(100) = NULL,
    @BloodGroup         NVARCHAR(5) = NULL,
    @RegistrationYear   INT = NULL,
    @PasswordHash       NVARCHAR(255) = NULL,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* The class must belong to THIS school. Without this check a School A
           admin passing a School B class id would be stopped only by the
           composite FK, with an unhelpful error message. */
        DECLARE @ClassName NVARCHAR(50), @MaxStudents INT;

        IF @ClassId IS NOT NULL
        BEGIN
            SELECT @ClassName = ClassName, @MaxStudents = MaxStudents
            FROM dbo.Classes
            WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1;

            IF @ClassName IS NULL
            BEGIN
                SELECT 'Error: Class not found in this school' AS Result,
                       CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                       CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                       CAST(NULL AS NVARCHAR(10)) AS RollNumber;
                RETURN;
            END

            IF (SELECT COUNT(*) FROM dbo.Students
                 WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) >= @MaxStudents
            BEGIN
                SELECT 'Error: Class ' + @ClassName + ' is full' AS Result,
                       CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                       CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                       CAST(NULL AS NVARCHAR(10)) AS RollNumber;
                RETURN;
            END
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: Email already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* Default to the school's own academic year, not the calendar year, so
           admission numbers do not roll over mid-session. */
        SET @RegistrationYear = ISNULL(@RegistrationYear,
                                       dbo.fn_AcademicYear(@SchoolId, CAST(GETDATE() AS DATE)));

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        BEGIN TRANSACTION;

        /* Roll numbers are per class; a student with no class yet falls back to
           the school-wide admission counter. Claimed inside the transaction so
           a failed registration does not burn a number. */
        DECLARE @Seq INT;
        DECLARE @SeqName NVARCHAR(50) =
            CASE WHEN @ClassId IS NULL THEN N'Student'
                 ELSE N'Roll:' + CAST(@ClassId AS NVARCHAR(10)) END;

        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = @SeqName, @NextValue = @Seq OUTPUT;

        DECLARE @LabelForId NVARCHAR(50) = ISNULL(@ClassName, N'GEN');
        DECLARE @Username  NVARCHAR(80) = dbo.fn_GenerateStudentUsername(@Code, @LabelForId, @RegistrationYear, @Seq);
        DECLARE @StudentId NVARCHAR(40) = dbo.fn_GenerateStudentId(@Code, @LabelForId, @RegistrationYear, @Seq);
        DECLARE @RollNumber NVARCHAR(10) =
            CASE WHEN @ClassId IS NULL THEN NULL
                 ELSE RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END)
            END;

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Generated username already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        DECLARE @Hash NVARCHAR(255) = ISNULL(@PasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        /* Persons + Users + Addresses in one call; RoleId 4 is Student. Already
           inside this procedure's transaction, so a later failure unwinds all of
           it. */
        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @Hash,
            @RoleId                = 4,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = 1,
            @ActorUserId           = @PerformedByUserId,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        INSERT INTO dbo.Students (SchoolId, UserId, StudentId, ClassId, RollNumber, DateOfBirth,
                                  Gender, FatherName, MotherName, BloodGroup, AdmissionDate)
        VALUES (@SchoolId, @UserId, @StudentId, @ClassId, @RollNumber, @DateOfBirth,
                @Gender, @FatherName, @MotherName, @BloodGroup, CAST(GETDATE() AS DATE));

        DECLARE @StudentRecordId INT = CAST(SCOPE_IDENTITY() AS INT);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Register', @EntityType = 'Student', @EntityId = @StudentRecordId,
            @Details = @StudentId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @UserId AS UserId,
               @StudentRecordId AS StudentRecordId,
               @Username AS Username,
               @StudentId AS StudentId,
               @RollNumber AS RollNumber,
               /* ClassName is on StudentRegistrationResponseDTO and the class was
                  already looked up above, so the caller does not need a second
                  round trip to tell the admin which class the student landed in. */
               @ClassName AS ClassName;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
               CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
               CAST(NULL AS NVARCHAR(10)) AS RollNumber;
    END CATCH
END
GO

/*==============================================================================
  sp_PreviewStudentUsername -- show the admin what will be generated.

  Uses sp_PeekSequence, NOT sp_NextSequence: a preview must not consume a
  number. The value is therefore advisory -- if two admins preview at once they
  see the same one, and whoever saves first gets it.

  Returns: GeneratedUsername, GeneratedStudentId, GeneratedRollNumber
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PreviewStudentUsername
    @SchoolId           INT,
    @ClassId            INT = NULL,
    @RegistrationYear   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);
    DECLARE @ClassName NVARCHAR(50) = (SELECT ClassName FROM dbo.Classes
                                        WHERE SchoolId = @SchoolId AND Id = @ClassId);

    SET @RegistrationYear = ISNULL(@RegistrationYear,
                                   dbo.fn_AcademicYear(@SchoolId, CAST(GETDATE() AS DATE)));

    DECLARE @SeqName NVARCHAR(50) =
        CASE WHEN @ClassId IS NULL THEN N'Student'
             ELSE N'Roll:' + CAST(@ClassId AS NVARCHAR(10)) END;

    DECLARE @Seq INT;
    EXEC dbo.sp_PeekSequence @SchoolId = @SchoolId, @SequenceName = @SeqName, @NextValue = @Seq OUTPUT;

    DECLARE @Label NVARCHAR(50) = ISNULL(@ClassName, N'GEN');

    SELECT dbo.fn_GenerateStudentUsername(@Code, @Label, @RegistrationYear, @Seq) AS GeneratedUsername,
           dbo.fn_GenerateStudentId(@Code, @Label, @RegistrationYear, @Seq) AS GeneratedStudentId,
           CASE WHEN @ClassId IS NULL THEN NULL
                ELSE RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END)
           END AS GeneratedRollNumber;
END
GO

/*==============================================================================
  sp_GetStudentsWithDetails

  The class join is a LEFT JOIN now. The old INNER JOIN silently hid every
  student who had not been placed in a class yet.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsWithDetails
    @SchoolId   INT,
    @ClassId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.FatherName,
           s.MotherName,
           s.BloodGroup,
           s.AdmissionDate,
           s.IsActive,
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
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY c.Grade, c.Section, s.RollNumber;
END
GO

/*==============================================================================
  sp_GetStudentsForClass -- lightweight list for attendance and grade screens.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsForClass
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           u.Email,
           s.ClassId,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

/*==============================================================================
  sp_GetAllStudents -- NEW. The paged list behind GET /api/Students.

  Columns are exactly StudentDTO's, plus SchoolId. The three new read procedures
  below repeat this column list rather than sharing a view, because a view would
  have to live in 01_Schema.sql -- and that script is the create-everything one,
  so shipping a change to it means re-running the whole database.

  @IsActive is a filter, not a fixed predicate. Deactivated students have to be
  reachable: sp_DeleteStudent is a soft delete, and a school looking for a
  student who left last year is looking for exactly those rows.

  Filtering is on Students.IsActive alone. sp_DeleteStudent deactivates the
  Users row with it, so adding "AND u.IsActive = 1" would only ever hide a row
  whose account was disabled by hand -- and hiding it is what makes a student
  impossible to find or reactivate.

  Returns: the page, then a single TotalCount row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllStudents
    @SchoolId   INT,
    @ClassId    INT           = NULL,
    @IsActive   BIT           = NULL,   -- NULL = both
    @SearchTerm NVARCHAR(100) = NULL,
    @Page       INT           = 1,
    @PageSize   INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* Defensive, not decorative: page 0 would make OFFSET negative and raise. */
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 100 SET @PageSize = 100;   -- mirrors Constants.Settings.MaxPageSize

    /* A cleared search box posts ?searchTerm= rather than dropping the
       parameter, and '%%' would match every row including the empty ones. */
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');

    /* LIKE metacharacters typed into a search box stand for themselves. Escape
       the bracket first, or the escapes added for % and _ get escaped in turn. */
    DECLARE @Pattern NVARCHAR(320) =
        CASE WHEN @SearchTerm IS NULL THEN NULL
             ELSE N'%' + REPLACE(REPLACE(REPLACE(@SearchTerm, N'[', N'[[]'),
                                         N'%', N'[%]'), N'_', N'[_]') + N'%'
        END;

    SELECT s.Id,
           s.UserId,
           s.StudentId,
           u.Username,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.ClassId,
           c.ClassName,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           u.Address,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@Pattern IS NULL
           OR u.FirstName LIKE @Pattern
           OR u.LastName LIKE @Pattern
           OR u.FirstName + N' ' + u.LastName LIKE @Pattern
           OR u.Email LIKE @Pattern
           OR u.Username LIKE @Pattern
           OR s.StudentId LIKE @Pattern
           OR s.RollNumber LIKE @Pattern)
    /* Grade and RollNumber are both NVARCHAR, so '10' sorts before '2' as text.
       TRY_CONVERT first puts each in the order a person reads a register in; the
       text key breaks ties for the non-numeric ones ('KG', '12A'). */
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section,
             TRY_CONVERT(INT, s.RollNumber), s.RollNumber,
             u.FirstName, u.LastName
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@Pattern IS NULL
           OR u.FirstName LIKE @Pattern
           OR u.LastName LIKE @Pattern
           OR u.FirstName + N' ' + u.LastName LIKE @Pattern
           OR u.Email LIKE @Pattern
           OR u.Username LIKE @Pattern
           OR s.StudentId LIKE @Pattern
           OR s.RollNumber LIKE @Pattern);
END
GO

/*==============================================================================
  sp_GetStudentById -- NEW. The single read behind GET /api/Students/{id}.

  @IncludeInactive defaults to 1, as for sp_GetSubjectById and unlike
  sp_GetClassById: the list this is opened from can show deactivated students, so
  404ing on a row the user just clicked would be the bug, not the safeguard.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentById
    @SchoolId        INT,
    @StudentId       INT,          -- Students.Id, not the admission number
    @IncludeInactive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.UserId,
           s.StudentId,
           u.Username,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.ClassId,
           c.ClassName,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           u.Address,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND s.Id = @StudentId
      AND (@IncludeInactive = 1 OR s.IsActive = 1);
END
GO

/*==============================================================================
  sp_GetStudentsByClass -- NEW. Unpaged roster behind GET /students/by-class/{id}.

  Not the same thing as sp_GetStudentsForClass, which stays as the lightweight
  feed for the attendance and grade-entry screens. This one returns the full
  StudentDTO shape because that is what the endpoint is declared to return, and
  it is the picker feed for anything that has to choose a student in one class.

  Active students only by default: a roster is who is in the room.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsByClass
    @SchoolId        INT,
    @ClassId         INT,
    @IncludeInactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.UserId,
           s.StudentId,
           u.Username,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.ClassId,
           c.ClassName,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           u.Address,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND (@IncludeInactive = 1 OR s.IsActive = 1)
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber, u.FirstName, u.LastName;
END
GO

/*==============================================================================
  sp_AssignSubjectsToStudent -- NOW ACTUALLY WRITES.

  The old version looped @SubjectIds into a temp table, dropped it, and returned
  'Success' with a comment saying "here you would insert into a StudentSubjects
  table if you had one". Subject counts on the profile page were therefore
  always zero.

  @SubjectIds is a comma-separated list, unchanged, so the API call site does
  not move. Subjects not belonging to @SchoolId are ignored rather than
  triggering an FK error.

  Returns: Result, Message, SubjectsAssigned
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignSubjectsToStudent
    @SchoolId       INT,
    @StudentId      INT,              -- Students.Id
    @SubjectIds     NVARCHAR(MAX),
    @ReplaceExisting BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result,
                   'Student not found' AS Message, 0 AS SubjectsAssigned;
            RETURN;
        END

        DECLARE @Wanted TABLE (SubjectId INT PRIMARY KEY);

        INSERT INTO @Wanted (SubjectId)
        SELECT DISTINCT sub.Id
        FROM STRING_SPLIT(ISNULL(@SubjectIds, N''), ',') AS parts
        INNER JOIN dbo.Subjects AS sub
                ON sub.Id = TRY_CONVERT(INT, LTRIM(RTRIM(parts.value)))
               AND sub.SchoolId = @SchoolId
        WHERE TRY_CONVERT(INT, LTRIM(RTRIM(parts.value))) IS NOT NULL;

        BEGIN TRANSACTION;

        /* Re-activate rather than insert duplicates: UQ_StudentSubjects would
           reject a second row for the same pair after an unassign. */
        MERGE dbo.StudentSubjects AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId, SubjectId FROM @Wanted) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.SubjectId = src.SubjectId
        WHEN MATCHED THEN
            UPDATE SET IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, SubjectId, IsActive)
            VALUES (src.SchoolId, src.StudentId, src.SubjectId, 1);

        IF @ReplaceExisting = 1
        BEGIN
            UPDATE dbo.StudentSubjects
               SET IsActive = 0
             WHERE SchoolId = @SchoolId
               AND StudentId = @StudentId
               AND SubjectId NOT IN (SELECT SubjectId FROM @Wanted);
        END

        DECLARE @Count INT = (SELECT COUNT(*) FROM dbo.StudentSubjects
                               WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1);

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               'Subjects assigned successfully' AS Message,
               @Count AS SubjectsAssigned;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               ERROR_MESSAGE() AS Message, 0 AS SubjectsAssigned;
    END CATCH
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

/*==============================================================================
  sp_RemoveStudentSubject -- NEW. Unassign one subject from one student.

  The link is deactivated, not deleted, for the same reason everything else here
  is a soft delete: results and attendance recorded against the subject stay
  readable, and re-assigning it later revives this row rather than tripping
  UQ_StudentSubjects.

  Already-unassigned is reported as success. The caller asked for a state, not
  for an event, and a double-click on the unassign button should not produce an
  error the user cannot act on.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RemoveStudentSubject
    @SchoolId   INT,
    @StudentId  INT,          -- Students.Id
    @SubjectId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.StudentSubjects
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                          AND SubjectId = @SubjectId)
        BEGIN
            SELECT 'Error: That subject is not assigned to this student' AS Result;
            RETURN;
        END

        UPDATE dbo.StudentSubjects
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND StudentId = @StudentId
           AND SubjectId = @SubjectId
           AND IsActive = 1;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_AssignFeesToStudent -- NOW ACTUALLY WRITES.

  The old version was a stub: it returned 'Success' without touching the Fees
  table, so "assign fees" appeared to work and nothing was ever billed.

  @FeeAssignments is the JSON shape the old signature documented:
      [{"FeeTypeId":1,"Amount":1500,"DueDate":"2026-01-31","FeeMonth":1,"FeeYear":2026}]

  Duplicates for the same student / type / period are skipped rather than
  failing the batch (UX_Fees_School_Student_Type_Period enforces this anyway).

  PHASE 12: FeesCreated + FeesSkipped always equals the number of array
  elements sent. Malformed rows, out-of-range periods, inactive fee types and
  in-batch duplicates are all skipped and counted; a cancelled fee for the same
  period is revived.

  Returns: Result, Message, FeesCreated, FeesSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignFeesToStudent
    @SchoolId       INT,
    @StudentId      INT,
    @FeeAssignments NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result,
                   'Student not found' AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Students
                    WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 0)
        BEGIN
            SELECT 'Error: This student is no longer active and cannot be billed' AS Result,
                   'Student inactive' AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        /* An array specifically: a bare object passes ISJSON, and OPENJSON would
           then count its keys as though they were rows. */
        IF ISJSON(ISNULL(@FeeAssignments, N'')) <> 1
           OR LEFT(LTRIM(@FeeAssignments), 1) <> N'['
        BEGIN
            SELECT 'Error: FeeAssignments is not valid JSON' AS Result,
                   'Expected [{"FeeTypeId":1,"Amount":1500,"DueDate":"2026-01-31","FeeMonth":1,"FeeYear":2026}]' AS Message,
                   0 AS FeesCreated, 0 AS FeesSkipped;
            RETURN;
        END

        /* PHASE 12: @Requested is the length of the array as sent, counted
           BEFORE any filtering. It used to be counted after the NULL filter,
           so a row with no DueDate vanished from both counts and a batch of
           three with one malformed row reported "2 created, 0 skipped". */
        DECLARE @Requested INT = (SELECT COUNT(*) FROM OPENJSON(@FeeAssignments));

        DECLARE @Rows TABLE (
            FeeTypeId INT, Amount DECIMAL(10,2), DueDate DATE, FeeMonth INT, FeeYear INT
        );

        /* Rows that would violate CK_Fees_* are dropped here and counted as
           skipped, rather than reaching the INSERT and failing the whole batch
           on a CHECK constraint. Two rows for the same type and period in one
           batch keep only the first -- the unique index would refuse the
           second and, again, take the batch with it. */
        INSERT INTO @Rows (FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        SELECT FeeTypeId, Amount, DueDate, FeeMonth, FeeYear
        FROM (
            SELECT v.*, ROW_NUMBER() OVER (PARTITION BY v.FeeTypeId, v.FeeMonth, v.FeeYear
                                           ORDER BY v.Ord) AS Rn
            FROM (
                SELECT CAST(j.[key] AS INT) AS Ord,
                       x.FeeTypeId, x.Amount, x.DueDate,
                       ISNULL(x.FeeMonth, MONTH(x.DueDate)) AS FeeMonth,
                       ISNULL(x.FeeYear,  YEAR(x.DueDate))  AS FeeYear
                FROM OPENJSON(@FeeAssignments) AS j
                CROSS APPLY OPENJSON(j.[value])
                     WITH (FeeTypeId INT       '$.FeeTypeId',
                           Amount    DECIMAL(10,2) '$.Amount',
                           DueDate   DATE      '$.DueDate',
                           FeeMonth  INT       '$.FeeMonth',
                           FeeYear   INT       '$.FeeYear') AS x
            ) AS v
            WHERE v.FeeTypeId IS NOT NULL
              AND v.Amount IS NOT NULL AND v.Amount > 0
              AND v.DueDate IS NOT NULL
              AND v.FeeMonth BETWEEN 1 AND 12
              AND v.FeeYear BETWEEN 2000 AND 2200
        ) AS d
        WHERE d.Rn = 1;

        BEGIN TRANSACTION;

        /* A cancelled fee (sp_CancelFee) for the same type and period still
           occupies UX_Fees_School_Student_Type_Period, so it is revived with
           the new amount and due date instead of colliding with it. */
        UPDATE f
           SET IsActive = 1, Amount = r.Amount, DueDate = r.DueDate, UpdatedAt = GETDATE()
        FROM dbo.Fees AS f
        INNER JOIN @Rows AS r
                ON r.FeeTypeId = f.FeeTypeId AND r.FeeMonth = f.FeeMonth AND r.FeeYear = f.FeeYear
        INNER JOIN dbo.FeeTypes AS ft
                ON ft.SchoolId = @SchoolId AND ft.Id = r.FeeTypeId AND ft.IsActive = 1
        WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId AND f.IsActive = 0;

        DECLARE @Revived INT = @@ROWCOUNT;

        INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        SELECT @SchoolId, @StudentId, r.FeeTypeId, r.Amount, r.DueDate, r.FeeMonth, r.FeeYear
        FROM @Rows AS r
        /* Only this school's ACTIVE fee types, so a stray id cannot bill
           against another tenant's pricing or a deleted fee head. */
        INNER JOIN dbo.FeeTypes AS ft
                ON ft.SchoolId = @SchoolId AND ft.Id = r.FeeTypeId AND ft.IsActive = 1
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Fees AS f
                           WHERE f.SchoolId = @SchoolId
                             AND f.StudentId = @StudentId
                             AND f.FeeTypeId = r.FeeTypeId
                             AND f.FeeMonth = r.FeeMonth
                             AND f.FeeYear = r.FeeYear);

        DECLARE @Created INT = @@ROWCOUNT + @Revived;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               'Fees assigned successfully' AS Message,
               @Created AS FeesCreated,
               @Requested - @Created AS FeesSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               ERROR_MESSAGE() AS Message, 0 AS FeesCreated, 0 AS FeesSkipped;
    END CATCH
END
GO

/*==============================================================================
  sp_CreateStudentFee -- Returns: Result, FeeId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateStudentFee
    @SchoolId   INT,
    @StudentId  INT,
    @FeeTypeId  INT,
    @Amount     DECIMAL(10,2),
    @DueDate    DATE,
    @FeeMonth   INT,
    @FeeYear    INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result, CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.FeeTypes WHERE SchoolId = @SchoolId AND Id = @FeeTypeId)
        BEGIN
            SELECT 'Error: Fee type not found in this school' AS Result, CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Fees
                    WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                      AND FeeTypeId = @FeeTypeId AND FeeMonth = @FeeMonth AND FeeYear = @FeeYear)
        BEGIN
            SELECT 'Error: Fee already exists for this student, type, month, and year' AS Result,
                   CAST(NULL AS INT) AS FeeId;
            RETURN;
        END

        INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
        VALUES (@SchoolId, @StudentId, @FeeTypeId, @Amount, @DueDate, @FeeMonth, @FeeYear);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS FeeId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS FeeId;
    END CATCH
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

/*==============================================================================
  sp_UpdateStudentProfile
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateStudentProfile
    @SchoolId       INT,
    @UserId         INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @DateOfBirth    DATE = NULL,
    @FatherName     NVARCHAR(100) = NULL,
    @MotherName     NVARCHAR(100) = NULL,
    @BloodGroup     NVARCHAR(5) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND UserId = @UserId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Name, phone and address are on Persons / Addresses now;
           sp_UpdateUserIdentity fans the edit out. @ModifiedBy defaults to the
           student themselves, since this is the self-service profile screen. */
        SET @ModifiedBy = ISNULL(@ModifiedBy, @UserId);

        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @ModifiedBy;

        UPDATE dbo.Students
           SET DateOfBirth = @DateOfBirth,
               FatherName  = @FatherName,
               MotherName  = @MotherName,
               BloodGroup  = @BloodGroup,
               UpdatedAt   = GETDATE()
         WHERE UserId = @UserId
           AND SchoolId = @SchoolId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Profile.Update', @EntityType = 'Student', @EntityId = @UserId;

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
  sp_UpdateStudent -- NEW. The administrator's edit, keyed on Students.Id.

  sp_UpdateStudentProfile above is the student's own edit and stays as it is: it
  is keyed on @UserId, defaults @ModifiedBy to the student, and cannot set
  Gender. An admin screen has the student record's id in hand, not the account's,
  and StudentUpdateDTO does carry Gender -- so this is a second procedure rather
  than four more optional parameters on that one.

  ClassId is deliberately absent, as it is from StudentUpdateDTO: moving a
  student between classes has to renumber the roll and check capacity, which is
  what sp_PromoteStudent does.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateStudent
    @SchoolId          INT,
    @StudentId         INT,              -- Students.Id, not the admission number
    @FirstName         NVARCHAR(50),
    @LastName          NVARCHAR(50),
    @Email             NVARCHAR(100),
    @PhoneNumber       NVARCHAR(15) = NULL,
    @DateOfBirth       DATE = NULL,
    @Gender            NVARCHAR(10) = NULL,
    @FatherName        NVARCHAR(100) = NULL,
    @MotherName        NVARCHAR(100) = NULL,
    @BloodGroup        NVARCHAR(5) = NULL,
    @Address           NVARCHAR(255) = NULL,
    @PerformedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Students
                                WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        SET @Email = NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'');

        IF @Email IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result;
            RETURN;
        END

        /* Checked here as well as inside sp_UpdateUserIdentity, which THROWs:
           the sentence a person reads should not depend on an error number. */
        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        SET @Gender = NULLIF(LTRIM(RTRIM(ISNULL(@Gender, N''))), N'');

        /* CK_Students_Gender would otherwise raise a constraint name at the
           user. The list is the constraint's, so the two cannot drift apart
           without this check failing loudly in 16_Verify.sql. */
        IF @Gender IS NOT NULL AND @Gender NOT IN (N'Male', N'Female', N'Other')
        BEGIN
            SELECT 'Error: Gender must be Male, Female or Other' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @PerformedByUserId;

        UPDATE dbo.Students
           SET DateOfBirth = @DateOfBirth,
               Gender      = @Gender,
               FatherName  = @FatherName,
               MotherName  = @MotherName,
               BloodGroup  = @BloodGroup,
               UpdatedAt   = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @StudentId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Update', @EntityType = 'Student', @EntityId = @StudentId;

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
  sp_PromoteStudent -- NEW. Move a student into another class.

  "Promote" is the only way a student changes class, which is why it also covers
  a sideways move between sections. Three things have to happen together:

  ROLL NUMBER
    Roll numbers are unique per class (UX_Students_School_Class_Roll), so
    carrying the old one across can collide with a student already in the target
    class. A fresh number is claimed from the target class's own counter, the
    same 'Roll:<ClassId>' sequence sp_RegisterStudent uses. The loop guards
    against a counter that has fallen behind rows inserted by hand.

  CAPACITY
    Checked against the target class's MaxStudents, exactly as registration does.
    Promoting into a full class is how a class quietly ends up over capacity.

  SUBJECTS
    Subjects belong to a grade. A student moving from grade 9 to grade 10 keeps
    their grade-9 enrolments otherwise, and every subject list, examination and
    report for them stays a year behind. Links to subjects that do not belong to
    the new class's grade are deactivated; the new grade's subjects are not
    assigned automatically, because which of them this student takes is a choice
    (POST /students/{id}/subjects makes it).

  @AcademicYear is recorded in the audit trail and nowhere else: this database
  has no promotion-history table, and inventing one here would be a schema
  change in a file that only holds procedures.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PromoteStudent
    @SchoolId          INT,
    @StudentId         INT,              -- Students.Id
    @NewClassId        INT,
    @AcademicYear      INT,
    @PerformedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @OldClassId INT, @StudentNumber NVARCHAR(40);

        SELECT @OldClassId = ClassId, @StudentNumber = StudentId
        FROM dbo.Students
        WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1;

        IF @StudentNumber IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF @AcademicYear IS NULL OR @AcademicYear < 2000 OR @AcademicYear > 2100
        BEGIN
            SELECT 'Error: Academic year must be a four-digit year' AS Result;
            RETURN;
        END

        DECLARE @NewClassName NVARCHAR(50), @NewGrade NVARCHAR(10), @MaxStudents INT;

        SELECT @NewClassName = ClassName, @NewGrade = Grade, @MaxStudents = MaxStudents
        FROM dbo.Classes
        WHERE SchoolId = @SchoolId AND Id = @NewClassId AND IsActive = 1;

        IF @NewClassName IS NULL
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result;
            RETURN;
        END

        IF @OldClassId = @NewClassId
        BEGIN
            SELECT 'Error: Student is already in ' + @NewClassName AS Result;
            RETURN;
        END

        IF (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @NewClassId AND IsActive = 1) >= @MaxStudents
        BEGIN
            SELECT 'Error: Class ' + @NewClassName + ' is full' AS Result;
            RETURN;
        END

        DECLARE @OldClassName NVARCHAR(50) = (SELECT ClassName FROM dbo.Classes
                                               WHERE SchoolId = @SchoolId AND Id = @OldClassId);

        BEGIN TRANSACTION;

        DECLARE @Seq INT,
                @Candidate NVARCHAR(10),
                @NewRoll NVARCHAR(10) = NULL,
                @Attempts INT = 0;
        DECLARE @SeqName NVARCHAR(50) = N'Roll:' + CAST(@NewClassId AS NVARCHAR(10));

        WHILE @NewRoll IS NULL AND @Attempts < 100
        BEGIN
            SET @Attempts += 1;

            EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = @SeqName,
                                     @NextValue = @Seq OUTPUT;

            /* Same three-digit shape sp_RegisterStudent produces, widening past
               999 rather than truncating. */
            SET @Candidate = RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)),
                                   CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END);

            IF NOT EXISTS (SELECT 1 FROM dbo.Students
                            WHERE SchoolId = @SchoolId AND ClassId = @NewClassId
                              AND RollNumber = @Candidate)
                SET @NewRoll = @Candidate;
        END

        IF @NewRoll IS NULL
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Could not allocate a free roll number in ' + @NewClassName AS Result;
            RETURN;
        END

        UPDATE dbo.Students
           SET ClassId    = @NewClassId,
               RollNumber = @NewRoll,
               UpdatedAt  = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @StudentId;

        UPDATE ss
           SET ss.IsActive = 0
        FROM dbo.StudentSubjects AS ss
        INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
        WHERE ss.SchoolId = @SchoolId
          AND ss.StudentId = @StudentId
          AND ss.IsActive = 1
          AND sub.Grade <> @NewGrade;

        DECLARE @Details NVARCHAR(400) =
            CONCAT(@StudentNumber, ': ', ISNULL(@OldClassName, N'no class'), ' -> ', @NewClassName,
                   N', roll ', @NewRoll, N', academic year ', @AcademicYear);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Promote', @EntityType = 'Student', @EntityId = @StudentId,
            @Details = @Details;

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
  sp_GetStudentProfileStats

  The old version read a StudentFees table with an IsPaid column. No script in
  this project ever created that table, so this procedure failed outright.
  Rewritten against the real Fees + FeePayments pair, where "paid" means the
  completed payments cover the fee amount.

  Column names kept: PresentDays, AbsentDays, TotalDays, TotalResults,
  AverageMarks, HighestMarks, TotalFees, PaidAmount, PendingAmount, SubjectCount
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentProfileStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                               WHERE SchoolId = @SchoolId AND UserId = @UserId);

    SELECT (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsPresent = 1) AS PresentDays,
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsPresent = 0) AS AbsentDays,
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId) AS TotalDays,

           (SELECT COUNT(*) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalResults,
           (SELECT AVG(CAST(ObtainedMarks AS FLOAT)) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS AverageMarks,
           (SELECT MAX(ObtainedMarks) FROM dbo.Results
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS HighestMarks,

           (SELECT COUNT(*) FROM dbo.Fees
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalFees,
           (SELECT ISNULL(SUM(fp.AmountPaid), 0)
              FROM dbo.FeePayments AS fp
              INNER JOIN dbo.Fees AS f ON f.SchoolId = fp.SchoolId AND f.Id = fp.FeeId
             WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId
               AND f.IsActive = 1 AND fp.PaymentStatus = 'Completed') AS PaidAmount,
           (SELECT ISNULL(SUM(CASE WHEN f.Amount - ISNULL(p.Paid, 0) > 0
                                   THEN f.Amount - ISNULL(p.Paid, 0) ELSE 0 END), 0)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId AND f.StudentId = @StudentId AND f.IsActive = 1) AS PendingAmount,

           (SELECT COUNT(*) FROM dbo.StudentSubjects
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS SubjectCount;
END
GO

/*==============================================================================
  sp_GetStudentChildren -- the students linked to a parent (parent portal).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentChildren
    @SchoolId       INT,
    @ParentUserId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.BloodGroup,
           s.AdmissionDate,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           sp.Relationship
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Parents  AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
    INNER JOIN dbo.Students AS s ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId  AND u.Id = s.UserId
    LEFT JOIN  dbo.Classes  AS c ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE sp.SchoolId = @SchoolId
      AND p.UserId = @ParentUserId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

/*==============================================================================
  sp_LinkStudentParent -- attach a parent to a student.

  Both ids are checked against @SchoolId first, so a mismatched pair produces a
  clear message rather than a composite-FK violation.

  ADDED IN THE PARENTS PASS: @Relationship is validated here rather than left to
  CK_StudentParents_Relationship. The constraint still backs it up, but its
  violation message ('The UPDATE statement conflicted with the CHECK constraint
  "CK_StudentParents_Relationship"...') reached the admin verbatim, and it does not
  say which three words are allowed. The unlink half of this pair lives in
  17_Procs_Parents.sql as sp_UnlinkStudentParent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LinkStudentParent
    @SchoolId           INT,
    @StudentId          INT,
    @ParentId           INT,
    @Relationship       NVARCHAR(20),
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Parents WHERE SchoolId = @SchoolId AND Id = @ParentId)
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        SET @Relationship = NULLIF(LTRIM(RTRIM(ISNULL(@Relationship, N''))), N'');

        IF @Relationship IS NULL OR @Relationship NOT IN (N'Father', N'Mother', N'Guardian')
        BEGIN
            SELECT 'Error: Relationship must be Father, Mother or Guardian' AS Result;
            RETURN;
        END

        MERGE dbo.StudentParents AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId, @ParentId AS ParentId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ParentId = src.ParentId
        WHEN MATCHED THEN
            UPDATE SET Relationship = @Relationship, IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ParentId, Relationship, IsActive)
            VALUES (src.SchoolId, src.StudentId, src.ParentId, @Relationship, 1);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Parent.Link', @EntityType = 'StudentParent', @EntityId = @StudentId,
            @Details = @Relationship;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteStudent -- soft delete, refusing to orphan history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteStudent
    @SchoolId           INT,
    @StudentId          INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Students
                                WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Attendance WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
           OR EXISTS (SELECT 1 FROM dbo.Results WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
           OR EXISTS (SELECT 1 FROM dbo.Fees    WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
        BEGIN
            SELECT 'Error: Cannot delete student with attendance, result or fee history. Deactivate the account instead.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND StudentId = @StudentId;

        UPDATE dbo.StudentParents SET IsActive = 0
         WHERE SchoolId = @SchoolId AND StudentId = @StudentId;

        UPDATE dbo.Students SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @StudentId;

        UPDATE dbo.Users
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @UserId;

        UPDATE dbo.Persons
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = (SELECT PersonId FROM dbo.Users WHERE Id = @UserId);

        UPDATE dbo.RefreshTokens SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Delete', @EntityType = 'Student', @EntityId = @StudentId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

PRINT '=== 06_Procs_Students.sql complete ===';
GO

SET NOEXEC OFF;
GO
