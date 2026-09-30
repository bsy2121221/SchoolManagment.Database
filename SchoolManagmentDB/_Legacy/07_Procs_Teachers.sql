/*==============================================================================
  07_Procs_Teachers.sql  --  Teacher registration, profile, subjects,
                             subject/class assignments.

  BREAKING CHANGE -- READ THIS
    @TeacherId ALWAYS MEANS Teachers.Id in this file.

    Previously it meant Users.Id in some places (Classes.ClassTeacherId,
    TeacherSchedule, TeacherSubjectAssignments, sp_GetTeacherClasses) and
    Teachers.Id in others (TeacherSubjects), so any join between the two groups
    silently matched the wrong rows. All three columns now hold Teachers.Id.

    The API resolves the logged-in user's Teachers.Id once per request with
    sp_GetTeacherByUserId, then passes that everywhere.

  OTHER FIXES
    * Employee IDs came from MAX(CAST(SUBSTRING(EmployeeId, ...))) over a
      globally unique column -- broken as soon as a second school exists, and
      racy besides. They now come from the per-school 'Employee' sequence.
    * fn_GenerateTeacherUsername looped "WHILE EXISTS ... SET @Username = base +
      counter", which is a read-then-write race. The suffix is now a claimed
      sequence value.
    * sp_UpdateTeacherDetails called sp_AssignSubjectsToTeacher, whose result set
      arrived first and shadowed its own -- Dapper read the wrong row. The inner
      procedure is now silent when called nested.
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
  sp_AssignSubjectsToTeacher

  @Silent = 1 suppresses the result set so this can be called from inside
  another procedure without shadowing the outer one's output.

  Returns (when not silent): Result, SubjectsAssigned
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignSubjectsToTeacher
    @SchoolId   INT,
    @TeacherId  INT,              -- Teachers.Id
    @SubjectIds NVARCHAR(MAX),    -- comma-separated
    @Silent     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Teachers WHERE SchoolId = @SchoolId AND Id = @TeacherId)
        BEGIN
            IF @Silent = 0
                SELECT 'Error: Teacher not found in this school' AS Result, 0 AS SubjectsAssigned;
            RETURN;
        END

        DECLARE @Wanted TABLE (SubjectId INT PRIMARY KEY);

        /* Only this school's subjects survive the join, so a stray id from
           another tenant is dropped instead of raising an FK error. */
        INSERT INTO @Wanted (SubjectId)
        SELECT DISTINCT sub.Id
        FROM STRING_SPLIT(ISNULL(@SubjectIds, N''), ',') AS parts
        INNER JOIN dbo.Subjects AS sub
                ON sub.Id = TRY_CONVERT(INT, LTRIM(RTRIM(parts.value)))
               AND sub.SchoolId = @SchoolId
        WHERE TRY_CONVERT(INT, LTRIM(RTRIM(parts.value))) IS NOT NULL;

        BEGIN TRANSACTION;

        MERGE dbo.TeacherSubjects AS tgt
        USING (SELECT @SchoolId AS SchoolId, @TeacherId AS TeacherId, SubjectId FROM @Wanted) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.TeacherId = src.TeacherId
            AND tgt.SubjectId = src.SubjectId
        WHEN MATCHED THEN
            UPDATE SET IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, TeacherId, SubjectId, IsActive)
            VALUES (src.SchoolId, src.TeacherId, src.SubjectId, 1);

        UPDATE dbo.TeacherSubjects
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND TeacherId = @TeacherId
           AND SubjectId NOT IN (SELECT SubjectId FROM @Wanted);

        DECLARE @Count INT = (SELECT COUNT(*) FROM dbo.TeacherSubjects
                               WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1);

        COMMIT TRANSACTION;

        IF @Silent = 0
            SELECT 'Success' AS Result, @Count AS SubjectsAssigned;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        IF @Silent = 0
            SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS SubjectsAssigned;
        ELSE
            THROW;
    END CATCH
END
GO

/*==============================================================================
  sp_RegisterTeacher

  Returns: Result, UserId, TeacherRecordId, Username, EmployeeId
           (unchanged column names)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RegisterTeacher
    @SchoolId           INT,
    @FirstName          NVARCHAR(50),
    @LastName           NVARCHAR(50),
    @Email              NVARCHAR(100),
    @PhoneNumber        NVARCHAR(15) = NULL,
    @Address            NVARCHAR(255) = NULL,
    @Subject            NVARCHAR(100) = NULL,
    @Qualification      NVARCHAR(255) = NULL,
    @Experience         INT = NULL,
    @Salary             DECIMAL(10,2) = NULL,
    @SubjectIds         NVARCHAR(MAX) = NULL,   -- comma-separated
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
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: Email already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        BEGIN TRANSACTION;

        DECLARE @Seq INT;
        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = N'Employee', @NextValue = @Seq OUTPUT;

        DECLARE @Username   NVARCHAR(80) = dbo.fn_GenerateTeacherUsername(@Code, @FirstName, @LastName, @Seq);
        DECLARE @EmployeeId NVARCHAR(30) = dbo.fn_GenerateTeacherEmployeeId(@Code, @Seq);

        /* Two teachers with the same initial + surname collide on the name part
           but not on the sequence suffix, so this only trips on a genuine
           duplicate. */
        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Generated username already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        DECLARE @Hash NVARCHAR(255) = ISNULL(@PasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        /* Persons + Users + Addresses in one call; RoleId 3 is Teacher. */
        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @Hash,
            @RoleId                = 3,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = 1,
            @ActorUserId           = @PerformedByUserId,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        INSERT INTO dbo.Teachers (SchoolId, UserId, EmployeeId, Subject, Qualification,
                                  Experience, Salary, JoinDate)
        VALUES (@SchoolId, @UserId, @EmployeeId, @Subject, @Qualification,
                @Experience, @Salary, CAST(GETDATE() AS DATE));

        DECLARE @TeacherRecordId INT = CAST(SCOPE_IDENTITY() AS INT);

        IF NULLIF(LTRIM(RTRIM(ISNULL(@SubjectIds, N''))), N'') IS NOT NULL
            EXEC dbo.sp_AssignSubjectsToTeacher
                 @SchoolId = @SchoolId, @TeacherId = @TeacherRecordId,
                 @SubjectIds = @SubjectIds, @Silent = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Teacher.Register', @EntityType = 'Teacher', @EntityId = @TeacherRecordId,
            @Details = @EmployeeId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @UserId AS UserId,
               @TeacherRecordId AS TeacherRecordId,
               @Username AS Username,
               @EmployeeId AS EmployeeId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
               CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
    END CATCH
END
GO

/*==============================================================================
  sp_PreviewTeacherUsername -- peeks the sequence, does not consume it.

  Returns: GeneratedUsername, GeneratedEmployeeId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PreviewTeacherUsername
    @SchoolId   INT,
    @FirstName  NVARCHAR(50),
    @LastName   NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);
    DECLARE @Seq INT;

    EXEC dbo.sp_PeekSequence @SchoolId = @SchoolId, @SequenceName = N'Employee', @NextValue = @Seq OUTPUT;

    SELECT dbo.fn_GenerateTeacherUsername(@Code, @FirstName, @LastName, @Seq) AS GeneratedUsername,
           dbo.fn_GenerateTeacherEmployeeId(@Code, @Seq) AS GeneratedEmployeeId;
END
GO

/*==============================================================================
  sp_GetTeachersWithDetails

  @SubjectId now filters with EXISTS instead of inside the WHERE of the
  aggregation. The old form dropped every OTHER subject from SubjectNames when
  the filter was supplied, so a filtered list showed teachers as if they taught
  only one subject.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeachersWithDetails
    @SchoolId   INT,
    @SubjectId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           t.Salary,
           t.JoinDate,
           t.IsActive,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           STRING_AGG(s.SubjectName, ', ') AS SubjectNames,
           STRING_AGG(CAST(s.Id AS NVARCHAR(10)), ',') AS SubjectIds,
           t.SchoolId
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.TeacherSubjects AS ts
           ON ts.SchoolId = t.SchoolId AND ts.TeacherId = t.Id AND ts.IsActive = 1
    LEFT JOIN dbo.Subjects AS s
           ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    WHERE t.SchoolId = @SchoolId
      AND t.IsActive = 1
      AND u.IsActive = 1
      AND (@SubjectId IS NULL
           OR EXISTS (SELECT 1 FROM dbo.TeacherSubjects AS f
                       WHERE f.SchoolId = t.SchoolId AND f.TeacherId = t.Id
                         AND f.SubjectId = @SubjectId AND f.IsActive = 1))
    GROUP BY t.Id, t.EmployeeId, t.Subject, t.Qualification, t.Experience, t.Salary,
             t.JoinDate, t.IsActive, u.Id, u.Username, u.Email, u.FirstName, u.LastName,
             u.PhoneNumber, u.Address, u.RequirePasswordChange, t.SchoolId
    ORDER BY t.JoinDate DESC;
END
GO

/*==============================================================================
  sp_GetTeacherSubjects -- @TeacherId is Teachers.Id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherSubjects
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.SubjectName,
           s.SubjectCode,
           s.Grade,
           s.IsActive,
           ts.Id AS TeacherSubjectId,
           ts.IsActive AS IsAssigned
    FROM dbo.Subjects AS s
    INNER JOIN dbo.TeacherSubjects AS ts
            ON ts.SchoolId = s.SchoolId AND ts.SubjectId = s.Id
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.IsActive = 1
    ORDER BY s.SubjectName;
END
GO

/*==============================================================================
  sp_GetAllSubjectsForTeacher -- the pick list on the registration form.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSubjectsForTeacher
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName;
END
GO

/*==============================================================================
  sp_UpdateTeacherDetails -- Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateTeacherDetails
    @SchoolId       INT,
    @TeacherId      INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Subject        NVARCHAR(100) = NULL,
    @Qualification  NVARCHAR(255) = NULL,
    @Experience     INT = NULL,
    @Salary         DECIMAL(10,2) = NULL,
    @SubjectIds     NVARCHAR(MAX) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Teachers
                                WHERE SchoolId = @SchoolId AND Id = @TeacherId);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
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
            @ActorUserId = @ModifiedBy;

        UPDATE dbo.Teachers
           SET Subject       = @Subject,
               Qualification = @Qualification,
               Experience    = @Experience,
               Salary        = @Salary,
               UpdatedAt     = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @TeacherId;

        /* @Silent = 1: without it the inner result set arrives first and Dapper's
           FirstOrDefault() reads that instead of this procedure's Result. */
        IF @SubjectIds IS NOT NULL
            EXEC dbo.sp_AssignSubjectsToTeacher
                 @SchoolId = @SchoolId, @TeacherId = @TeacherId,
                 @SubjectIds = @SubjectIds, @Silent = 1;

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
  sp_GetTeacherProfile

  AssignedClasses now matches c.ClassTeacherId against t.Id, not u.Id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherProfile
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           t.Salary,
           t.JoinDate,
           t.IsActive,

           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           u.CreatedAt,
           u.UpdatedAt,

           (SELECT STRING_AGG(sub.SubjectName, ', ')
              FROM dbo.TeacherSubjects AS ts
              INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ts.SchoolId AND sub.Id = ts.SubjectId
             WHERE ts.SchoolId = t.SchoolId AND ts.TeacherId = t.Id AND ts.IsActive = 1) AS AssignedSubjects,

           (SELECT STRING_AGG(CONCAT(c.Grade, c.Section, ' (', c.ClassName, ')'), ', ')
              FROM dbo.Classes AS c
             WHERE c.SchoolId = t.SchoolId AND c.ClassTeacherId = t.Id AND c.IsActive = 1) AS AssignedClasses,

           t.SchoolId,
           sch.SchoolCode,
           sch.SchoolName
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Schools AS sch ON sch.Id = t.SchoolId
    WHERE t.SchoolId = @SchoolId
      AND t.UserId = @UserId
      AND t.IsActive = 1;
END
GO

/*==============================================================================
  sp_UpdateTeacherProfile -- self-service; Salary is deliberately not editable.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateTeacherProfile
    @SchoolId       INT,
    @UserId         INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Subject        NVARCHAR(100) = NULL,
    @Qualification  NVARCHAR(255) = NULL,
    @Experience     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Teachers
                        WHERE SchoolId = @SchoolId AND UserId = @UserId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Self-service, so the teacher is their own modifier. */
        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @UserId;

        UPDATE dbo.Teachers
           SET Subject       = @Subject,
               Qualification = @Qualification,
               Experience    = @Experience,
               UpdatedAt     = GETDATE()
         WHERE SchoolId = @SchoolId AND UserId = @UserId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Profile.Update', @EntityType = 'Teacher', @EntityId = @UserId;

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
  sp_GetTeacherProfileStats

  Every count used to compare Classes.ClassTeacherId against @UserId. Since that
  column holds Teachers.Id, all five numbers were wrong (usually zero, or
  another teacher's figures when the ids happened to coincide). They now compare
  against the resolved Teachers.Id.

  Column names kept: ClassesAssigned, StudentsUnderCare, SubjectsAssigned,
  AttendanceMarkedLastMonth, ResultsEnteredLastMonth
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherProfileStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                               WHERE SchoolId = @SchoolId AND UserId = @UserId);

    DECLARE @Since DATE = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);

    SELECT (SELECT COUNT(*) FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1) AS ClassesAssigned,

           (SELECT COUNT(DISTINCT s.Id)
              FROM dbo.Classes AS c
              INNER JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id
             WHERE c.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
               AND c.IsActive = 1 AND s.IsActive = 1) AS StudentsUnderCare,

           (SELECT COUNT(*) FROM dbo.TeacherSubjects
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1) AS SubjectsAssigned,

           /* Attendance is credited to whoever marked it (MarkedBy is a
              Users.Id), which is more accurate than the old "any attendance in a
              class I happen to own". */
           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND MarkedBy = @UserId
               AND AttendanceDate >= @Since) AS AttendanceMarkedLastMonth,

           (SELECT COUNT(*)
              FROM dbo.Results AS r
              INNER JOIN dbo.Students AS s ON s.SchoolId = r.SchoolId AND s.Id = r.StudentId
              INNER JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
             WHERE r.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
               AND r.CreatedAt >= @Since) AS ResultsEnteredLastMonth;
END
GO

/*==============================================================================
  sp_GetTeacherClasses -- @TeacherId is Teachers.Id (was Users.Id).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherClasses
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           COUNT(s.Id) AS StudentCount
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Students AS s
           ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND c.ClassTeacherId = @TeacherId
      AND c.IsActive = 1
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section;
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

/*==============================================================================
  sp_AssignTeacherToSubjectClass -- NEW.

  TeacherSubjectAssignments gates grade entry (sp_GetStudentsForGradeEntry
  refuses without a row here) but no procedure ever wrote to it, so grade entry
  could only be enabled by hand-inserting rows.

  Returns: Result, AssignmentId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignTeacherToSubjectClass
    @SchoolId   INT,
    @TeacherId  INT,
    @SubjectId  INT,
    @ClassId    INT,
    @IsActive   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Teachers WHERE SchoolId = @SchoolId AND Id = @TeacherId)
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects WHERE SchoolId = @SchoolId AND Id = @SubjectId)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Classes WHERE SchoolId = @SchoolId AND Id = @ClassId)
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        MERGE dbo.TeacherSubjectAssignments AS tgt
        USING (SELECT @SchoolId AS SchoolId, @TeacherId AS TeacherId,
                      @SubjectId AS SubjectId, @ClassId AS ClassId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.TeacherId = src.TeacherId
            AND tgt.SubjectId = src.SubjectId
            AND tgt.ClassId = src.ClassId
        WHEN MATCHED THEN
            UPDATE SET IsActive = @IsActive
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, TeacherId, SubjectId, ClassId, IsActive)
            VALUES (src.SchoolId, src.TeacherId, src.SubjectId, src.ClassId, @IsActive);

        SELECT 'Success' AS Result,
               (SELECT Id FROM dbo.TeacherSubjectAssignments
                 WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId
                   AND SubjectId = @SubjectId AND ClassId = @ClassId) AS AssignmentId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS AssignmentId;
    END CATCH
END
GO

/*==============================================================================
  sp_GetAvailableTeachers -- pick list for "class teacher".

  Id is now Teachers.Id, because that is what Classes.ClassTeacherId stores.
  The old version returned Users.Id here, so the value the UI sent back as
  ClassTeacherId pointed at the wrong table. UserId is returned alongside for
  screens that need it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAvailableTeachers
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           u.Id AS UserId,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           (SELECT COUNT(*) FROM dbo.Classes AS c
             WHERE c.SchoolId = t.SchoolId AND c.ClassTeacherId = t.Id AND c.IsActive = 1) AS CurrentClasses
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    WHERE t.SchoolId = @SchoolId
      AND u.RoleId = 3          -- Teacher
      AND u.IsActive = 1
      AND t.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

/*==============================================================================
  sp_DeleteTeacher -- soft delete.

  The class guard compared ClassTeacherId to the teacher's Users.Id, which never
  matched, so a teacher owning classes could be deleted and those classes were
  left pointing at a deactivated row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteTeacher
    @SchoolId           INT,
    @TeacherId          INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Teachers
                                WHERE SchoolId = @SchoolId AND Id = @TeacherId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Cannot delete teacher who is assigned to active classes' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Attendance WHERE SchoolId = @SchoolId AND MarkedBy = @UserId)
        BEGIN
            SELECT 'Error: Cannot delete teacher who has historical attendance data' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.TeacherSubjects SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.TeacherSchedule SET IsActive = 0
         WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

        UPDATE dbo.Teachers SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @TeacherId;

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
            @Action = 'Teacher.Delete', @EntityType = 'Teacher', @EntityId = @TeacherId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

PRINT '=== 07_Procs_Teachers.sql complete ===';
GO

SET NOEXEC OFF;
GO
