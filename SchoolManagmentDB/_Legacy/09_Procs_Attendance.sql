/*==============================================================================
  09_Procs_Attendance.sql  --  Marking and attendance reports.

  FIX: sp_MarkAttendance was IF EXISTS -> UPDATE -> ELSE INSERT. Two teachers
  submitting the same class at the same moment both see "not exists" and both
  INSERT, so one of them gets a duplicate-key error and loses the whole
  submission. Rewritten as MERGE ... WITH (HOLDLOCK), which takes a range lock
  on the (SchoolId, StudentId, AttendanceDate) key so the second session waits
  and then takes the UPDATE branch.

  NEW: sp_MarkAttendanceBulk marks a whole class in one round trip. The API
  currently loops sp_MarkAttendance once per student, so a class of 40 is 40
  round trips and 40 separate transactions -- a failure halfway through leaves
  the register half-marked.

  MarkedBy is a Users.Id (the person marking), not a Teachers.Id.
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
  sp_MarkAttendance -- Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_MarkAttendance
    @SchoolId       INT,
    @StudentId      INT,
    @ClassId        INT,
    @AttendanceDate DATE,
    @IsPresent      BIT,
    @Remarks        NVARCHAR(255) = NULL,
    @MarkedBy       INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* Both ids must belong to this school, and the student must actually be
           in that class -- otherwise a mistyped ClassId files the record against
           the wrong register and every class report double-counts. */
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId
                          AND ClassId = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Student is not enrolled in that class' AS Result;
            RETURN;
        END

        MERGE dbo.Attendance WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId,
                      @AttendanceDate AS AttendanceDate) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.AttendanceDate = src.AttendanceDate
        WHEN MATCHED THEN
            UPDATE SET IsPresent = @IsPresent,
                       Remarks   = @Remarks,
                       ClassId   = @ClassId,
                       MarkedBy  = @MarkedBy,
                       MarkedAt  = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ClassId, AttendanceDate, IsPresent, Remarks, MarkedBy)
            VALUES (src.SchoolId, src.StudentId, @ClassId, src.AttendanceDate,
                    @IsPresent, @Remarks, @MarkedBy);

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_MarkAttendanceBulk -- NEW. One transaction for a whole class.

  @Records: [{"StudentId":12,"IsPresent":true,"Remarks":"late"}, ...]

  Students not enrolled in @ClassId are skipped and counted, so one bad id does
  not abort the register.

  Returns: Result, RecordsMarked, RecordsSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_MarkAttendanceBulk
    @SchoolId       INT,
    @ClassId        INT,
    @AttendanceDate DATE,
    @Records        NVARCHAR(MAX),
    @MarkedBy       INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF ISJSON(ISNULL(@Records, N'')) <> 1
        BEGIN
            SELECT 'Error: Records is not valid JSON' AS Result, 0 AS RecordsMarked, 0 AS RecordsSkipped;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result, 0 AS RecordsMarked, 0 AS RecordsSkipped;
            RETURN;
        END

        DECLARE @In TABLE (StudentId INT PRIMARY KEY, IsPresent BIT, Remarks NVARCHAR(255));

        INSERT INTO @In (StudentId, IsPresent, Remarks)
        SELECT j.StudentId, ISNULL(j.IsPresent, 0), j.Remarks
        FROM OPENJSON(@Records)
             WITH (StudentId INT           '$.StudentId',
                   IsPresent BIT           '$.IsPresent',
                   Remarks   NVARCHAR(255) '$.Remarks') AS j
        WHERE j.StudentId IS NOT NULL;

        DECLARE @Requested INT = (SELECT COUNT(*) FROM @In);

        /* Only students genuinely in this class of this school. */
        DECLARE @Valid TABLE (StudentId INT PRIMARY KEY, IsPresent BIT, Remarks NVARCHAR(255));

        INSERT INTO @Valid (StudentId, IsPresent, Remarks)
        SELECT i.StudentId, i.IsPresent, i.Remarks
        FROM @In AS i
        INNER JOIN dbo.Students AS s
                ON s.SchoolId = @SchoolId AND s.Id = i.StudentId
               AND s.ClassId = @ClassId AND s.IsActive = 1;

        BEGIN TRANSACTION;

        MERGE dbo.Attendance WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, StudentId, @AttendanceDate AS AttendanceDate,
                      IsPresent, Remarks
                 FROM @Valid) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.AttendanceDate = src.AttendanceDate
        WHEN MATCHED THEN
            UPDATE SET IsPresent = src.IsPresent,
                       Remarks   = src.Remarks,
                       ClassId   = @ClassId,
                       MarkedBy  = @MarkedBy,
                       MarkedAt  = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ClassId, AttendanceDate, IsPresent, Remarks, MarkedBy)
            VALUES (src.SchoolId, src.StudentId, @ClassId, src.AttendanceDate,
                    src.IsPresent, src.Remarks, @MarkedBy);

        DECLARE @Marked INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @Marked AS RecordsMarked,
               @Requested - @Marked AS RecordsSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS RecordsMarked, 0 AS RecordsSkipped;
    END CATCH
END
GO

/*==============================================================================
  sp_GetClassAttendance -- the register for one date.

  Driven from Students with a LEFT JOIN, so students with nothing marked yet
  appear with a NULL IsPresent. The old INNER JOIN from Attendance returned only
  already-marked students, which made a freshly opened register look empty and
  hid anyone the teacher had skipped.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassAttendance
    @SchoolId       INT,
    @ClassId        INT,
    @AttendanceDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Id,
           s.Id AS StudentId,
           a.IsPresent,
           a.Remarks,
           a.MarkedAt,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           u.Email
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Attendance AS a
           ON a.SchoolId = s.SchoolId
          AND a.StudentId = s.Id
          AND a.AttendanceDate = @AttendanceDate
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

/*==============================================================================
  sp_GetStudentAttendance
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentAttendance
    @SchoolId   INT,
    @StudentId  INT,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT a.Id,
           a.AttendanceDate,
           a.IsPresent,
           a.Remarks,
           a.MarkedAt,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.Attendance AS a
    INNER JOIN dbo.Classes AS c ON c.SchoolId = a.SchoolId AND c.Id = a.ClassId
    WHERE a.SchoolId = @SchoolId
      AND a.StudentId = @StudentId
      AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    ORDER BY a.AttendanceDate DESC;
END
GO

/*==============================================================================
  sp_GetAttendanceSummary -- NEW. Per-student percentages over a date range.

  Returns: StudentId, StudentNumber, RollNumber, FirstName, LastName,
           ClassId, ClassName, Grade, Section,
           PresentDays, AbsentDays, TotalDays, AttendancePercentage
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAttendanceSummary
    @SchoolId   INT,
    @ClassId    INT = NULL,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END) AS PresentDays,
           SUM(CASE WHEN a.IsPresent = 0 THEN 1 ELSE 0 END) AS AbsentDays,
           COUNT(a.Id) AS TotalDays,
           /* NULLIF avoids divide-by-zero for a student with nothing marked;
              the column comes back NULL rather than failing the whole report. */
           CAST(ROUND(100.0 * SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END)
                      / NULLIF(COUNT(a.Id), 0), 2) AS DECIMAL(5,2)) AS AttendancePercentage
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN dbo.Attendance AS a
           ON a.SchoolId = s.SchoolId
          AND a.StudentId = s.Id
          AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND s.IsActive = 1
      AND u.IsActive = 1
    GROUP BY s.Id, s.StudentId, s.RollNumber, u.FirstName, u.LastName,
             c.Id, c.ClassName, c.Grade, c.Section
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section,
             TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

/*==============================================================================
  sp_GetDailyAttendanceReport -- NEW. One row per date for a class.

  Returns: AttendanceDate, PresentCount, AbsentCount, TotalMarked,
           AttendancePercentage
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetDailyAttendanceReport
    @SchoolId   INT,
    @ClassId    INT = NULL,
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @StartDate IS NULL SET @StartDate = CAST(DATEADD(MONTH, -1, GETDATE()) AS DATE);
    IF @EndDate   IS NULL SET @EndDate   = CAST(GETDATE() AS DATE);

    SELECT a.AttendanceDate,
           SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END) AS PresentCount,
           SUM(CASE WHEN a.IsPresent = 0 THEN 1 ELSE 0 END) AS AbsentCount,
           COUNT(*) AS TotalMarked,
           CAST(ROUND(100.0 * SUM(CASE WHEN a.IsPresent = 1 THEN 1 ELSE 0 END)
                      / NULLIF(COUNT(*), 0), 2) AS DECIMAL(5,2)) AS AttendancePercentage
    FROM dbo.Attendance AS a
    WHERE a.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR a.ClassId = @ClassId)
      AND a.AttendanceDate BETWEEN @StartDate AND @EndDate
    GROUP BY a.AttendanceDate
    ORDER BY a.AttendanceDate DESC;
END
GO

PRINT '=== 09_Procs_Attendance.sql complete ===';
GO

SET NOEXEC OFF;
GO
