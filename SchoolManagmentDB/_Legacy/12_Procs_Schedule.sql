/*==============================================================================
  12_Procs_Schedule.sql  --  Teacher timetable.

  @TeacherId IS Teachers.Id. TeacherSchedule.TeacherId used to reference
  Users(Id), which is why timetable rows never lined up with TeacherSubjects.

  FIXES
    * DATEPART(WEEKDAY, GETDATE()) was used as the day number. That depends on
      the connection's DATEFIRST setting and returns 1 = SUNDAY under the default
      (DATEFIRST 7), while the column is documented 1 = Monday. Every "current
      class" lookup was therefore one day out. Replaced with a DATEFIRST-
      independent expression anchored on 1900-01-01, which was a Monday.
    * "Next class" filtered ts.DayOfWeek > @CurrentDay, which cannot wrap around
      the week -- after the last lesson on Sunday (and on Friday for a Mon-Fri
      timetable) it returned nothing instead of Monday's first lesson.
    * The clash check only looked at the teacher's own time. Two teachers could
      be booked into the same room in the same slot. Room is now checked too.
    * StartTimeFormatted / EndTimeFormatted were always NULL. FORMAT() on a TIME
      value goes through TimeSpan.ToString(), which has no 12-hour 'hh' or 'tt'
      specifier and returns NULL instead of raising -- so the UI's time labels
      were silently blank. The value is cast to DATETIME first.
    * The seven-way CASE for the day name was copy-pasted into four procedures;
      it is now dbo.fn_DayName.

  PHASE 13 (frontend Schedule module)
    * A clash now says what it clashes with. All three checks answered with a
      fixed sentence ("Time conflict with existing schedule"), so the person
      building a timetable had to go and find the other lesson themselves. The
      row is Result = 'Conflict', a Message naming the other lesson's subject,
      class or teacher, day and times, and ConflictWith = its Id.
    * The subject must be taught in the class's grade. Nothing stopped a grade 9
      subject being timetabled into 10-A.
    * @Room is trimmed and '' is NULL. An empty room was a room: every lesson
      saved with a blank room clashed with every other one in the same slot.
    * An update must name an ACTIVE entry. Editing a deleted entry from a stale
      screen quietly brought it back.
    * "Current" is half-open (StartTime <= now < EndTime), matching the clash
      rule. At 10:00 exactly a 09:00-10:00 lesson and a 10:00-11:00 lesson were
      both current, and TOP 1 picked the one that had just finished.
    * Current / next carry SubjectId and ClassId, so the widget can link.
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
  sp_GetTeacherSchedule -- the whole week.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherSchedule
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
           ts.IsActive,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.IsActive = 1
    ORDER BY ts.DayOfWeek, ts.StartTime;
END
GO

/*==============================================================================
  sp_GetTeacherScheduleByDay
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherScheduleByDay
    @SchoolId   INT,
    @TeacherId  INT,
    @DayOfWeek  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
           ts.IsActive,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.DayOfWeek = @DayOfWeek
      AND ts.IsActive = 1
    ORDER BY ts.StartTime;
END
GO

/*==============================================================================
  sp_GetTeacherCurrentAndNextClasses

  Returns TWO result sets, as before: the current lesson, then the next one.
  Read with QueryMultiple.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherCurrentAndNextClasses
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    /* 1900-01-01 was a Monday, so this yields 1 = Monday .. 7 = Sunday whatever
       DATEFIRST happens to be on the connection. */
    DECLARE @CurrentDay  INT  = (DATEDIFF(DAY, '19000101', CAST(GETDATE() AS DATE)) % 7) + 1;
    DECLARE @CurrentTime TIME = CAST(GETDATE() AS TIME);

    SELECT TOP 1
           'Current' AS ClassType,
           ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.DayOfWeek = @CurrentDay
      AND ts.StartTime <= @CurrentTime
      AND ts.EndTime > @CurrentTime
      AND ts.IsActive = 1
    ORDER BY ts.StartTime;

    /* DayOffset wraps: 0 = later today, 1..6 = a following day, 7 = this same
       weekday next week. Sunday evening therefore rolls forward to Monday
       instead of returning nothing. */
    SELECT TOP 1
           'Next' AS ClassType,
           ts.Id,
           ts.TeacherId,
           ts.DayOfWeek,
           ts.StartTime,
           ts.EndTime,
           ts.Room,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    WHERE ts.SchoolId = @SchoolId
      AND ts.TeacherId = @TeacherId
      AND ts.IsActive = 1
    ORDER BY CASE
               WHEN ts.DayOfWeek = @CurrentDay AND ts.StartTime > @CurrentTime THEN 0
               WHEN ts.DayOfWeek = @CurrentDay THEN 7
               ELSE (ts.DayOfWeek - @CurrentDay + 7) % 7
             END,
             ts.StartTime;
END
GO

/*==============================================================================
  sp_CreateOrUpdateScheduleEntry

  Returns: Result, Message, Id, ConflictWith -- all four on every path.
    Result 'Success'  -- Id is the entry written.
    Result 'Conflict' -- the slot is taken; ConflictWith is the entry in the way
                         and Message names it.
    Result 'Error'    -- anything else; Message says what.

  Clashes are checked teacher, then class, then room, and the first one found
  is reported. Two intervals overlap when each starts before the other ends, so
  back-to-back lessons (09:00-10:00 then 10:00-11:00) are not a clash.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateOrUpdateScheduleEntry
    @SchoolId   INT,
    @Id         INT = NULL,
    @TeacherId  INT,
    @SubjectId  INT,
    @ClassId    INT,
    @DayOfWeek  INT,
    @StartTime  TIME,
    @EndTime    TIME,
    @Room       NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Error NVARCHAR(400) = NULL;
    DECLARE @ClashId INT = NULL;
    DECLARE @ClashText NVARCHAR(400) = NULL;
    DECLARE @SubjectGrade NVARCHAR(10), @SubjectName NVARCHAR(100);
    DECLARE @ClassGrade NVARCHAR(10), @ClassName NVARCHAR(50);

    SET @Room = NULLIF(LTRIM(RTRIM(@Room)), N'');

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        SELECT @SubjectGrade = Grade, @SubjectName = SubjectName
        FROM dbo.Subjects
        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1;

        SELECT @ClassGrade = Grade, @ClassName = ClassName
        FROM dbo.Classes
        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1;

        IF @DayOfWeek NOT BETWEEN 1 AND 7
            SET @Error = N'DayOfWeek must be 1 (Monday) to 7 (Sunday)';
        ELSE IF @EndTime <= @StartTime
            SET @Error = N'End time must be after start time';
        ELSE IF NOT EXISTS (SELECT 1 FROM dbo.Teachers
                             WHERE SchoolId = @SchoolId AND Id = @TeacherId AND IsActive = 1)
            SET @Error = N'Teacher not found in this school';
        ELSE IF @SubjectGrade IS NULL
            SET @Error = N'Subject not found in this school';
        ELSE IF @ClassGrade IS NULL
            SET @Error = N'Class not found in this school';
        ELSE IF @SubjectGrade <> @ClassGrade
            SET @Error = CONCAT(@SubjectName, N' is a grade ', @SubjectGrade, N' subject and ',
                                @ClassName, N' is grade ', @ClassGrade);
        ELSE IF @Id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM dbo.TeacherSchedule
                              WHERE SchoolId = @SchoolId AND Id = @Id AND IsActive = 1)
            SET @Error = N'Schedule entry not found in this school';

        IF @Error IS NOT NULL
        BEGIN
            SELECT 'Error' AS Result, @Error AS Message,
                   CAST(NULL AS INT) AS Id, CAST(NULL AS INT) AS ConflictWith;
            RETURN;
        END

        /* The teacher is already teaching. */
        SELECT TOP 1
               @ClashId = ts.Id,
               @ClashText = CONCAT(N'This teacher already teaches ', s.SubjectName, N' to ',
                                   c.ClassName, N' on ', dbo.fn_DayName(ts.DayOfWeek), N' ',
                                   CONVERT(CHAR(5), ts.StartTime, 108), N'-',
                                   CONVERT(CHAR(5), ts.EndTime, 108))
        FROM dbo.TeacherSchedule AS ts
        INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
        INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
        WHERE ts.SchoolId = @SchoolId
          AND ts.TeacherId = @TeacherId
          AND ts.DayOfWeek = @DayOfWeek
          AND ts.IsActive = 1
          AND (@Id IS NULL OR ts.Id <> @Id)
          AND @StartTime < ts.EndTime
          AND @EndTime > ts.StartTime
        ORDER BY ts.StartTime;

        /* The class already has a lesson. */
        IF @ClashId IS NULL
            SELECT TOP 1
                   @ClashId = ts.Id,
                   @ClashText = CONCAT(c.ClassName, N' already has ', s.SubjectName, N' with ',
                                       u.FirstName, N' ', u.LastName, N' on ',
                                       dbo.fn_DayName(ts.DayOfWeek), N' ',
                                       CONVERT(CHAR(5), ts.StartTime, 108), N'-',
                                       CONVERT(CHAR(5), ts.EndTime, 108))
            FROM dbo.TeacherSchedule AS ts
            INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
            INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
            INNER JOIN dbo.Teachers AS t ON t.SchoolId = ts.SchoolId AND t.Id = ts.TeacherId
            INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId  AND u.Id = t.UserId
            WHERE ts.SchoolId = @SchoolId
              AND ts.ClassId = @ClassId
              AND ts.DayOfWeek = @DayOfWeek
              AND ts.IsActive = 1
              AND (@Id IS NULL OR ts.Id <> @Id)
              AND @StartTime < ts.EndTime
              AND @EndTime > ts.StartTime
            ORDER BY ts.StartTime;

        /* The room is taken. */
        IF @ClashId IS NULL AND @Room IS NOT NULL
            SELECT TOP 1
                   @ClashId = ts.Id,
                   @ClashText = CONCAT(N'Room ', @Room, N' is booked for ', s.SubjectName,
                                       N' with ', c.ClassName, N' on ',
                                       dbo.fn_DayName(ts.DayOfWeek), N' ',
                                       CONVERT(CHAR(5), ts.StartTime, 108), N'-',
                                       CONVERT(CHAR(5), ts.EndTime, 108))
            FROM dbo.TeacherSchedule AS ts
            INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
            INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
            WHERE ts.SchoolId = @SchoolId
              AND ts.Room = @Room
              AND ts.DayOfWeek = @DayOfWeek
              AND ts.IsActive = 1
              AND (@Id IS NULL OR ts.Id <> @Id)
              AND @StartTime < ts.EndTime
              AND @EndTime > ts.StartTime
            ORDER BY ts.StartTime;

        IF @ClashId IS NOT NULL
        BEGIN
            SELECT 'Conflict' AS Result, @ClashText AS Message,
                   CAST(NULL AS INT) AS Id, @ClashId AS ConflictWith;
            RETURN;
        END

        IF @Id IS NULL
        BEGIN
            INSERT INTO dbo.TeacherSchedule (SchoolId, TeacherId, SubjectId, ClassId,
                                             DayOfWeek, StartTime, EndTime, Room)
            VALUES (@SchoolId, @TeacherId, @SubjectId, @ClassId,
                    @DayOfWeek, @StartTime, @EndTime, @Room);

            SELECT 'Success' AS Result,
                   'Schedule entry created successfully' AS Message,
                   CAST(SCOPE_IDENTITY() AS INT) AS Id,
                   CAST(NULL AS INT) AS ConflictWith;
        END
        ELSE
        BEGIN
            UPDATE dbo.TeacherSchedule
               SET TeacherId = @TeacherId,
                   SubjectId = @SubjectId,
                   ClassId   = @ClassId,
                   DayOfWeek = @DayOfWeek,
                   StartTime = @StartTime,
                   EndTime   = @EndTime,
                   Room      = @Room,
                   UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND Id = @Id AND IsActive = 1;

            SELECT 'Success' AS Result,
                   'Schedule entry updated successfully' AS Message,
                   @Id AS Id,
                   CAST(NULL AS INT) AS ConflictWith;
        END
    END TRY
    BEGIN CATCH
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message,
               CAST(NULL AS INT) AS Id, CAST(NULL AS INT) AS ConflictWith;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteScheduleEntry

  Now scoped and existence-checked. The old version updated by Id alone, so any
  school could delete any other school's row, and deleting a non-existent id
  still reported success.

  Returns: Result, Message
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteScheduleEntry
    @SchoolId   INT,
    @Id         INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TeacherSchedule
                        WHERE SchoolId = @SchoolId AND Id = @Id AND IsActive = 1)
        BEGIN
            SELECT 'Error' AS Result, 'Schedule entry not found in this school' AS Message;
            RETURN;
        END

        UPDATE dbo.TeacherSchedule
           SET IsActive  = 0,
               UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @Id;

        SELECT 'Success' AS Result, 'Schedule entry deleted successfully' AS Message;
    END TRY
    BEGIN CATCH
        SELECT 'Error' AS Result, ERROR_MESSAGE() AS Message;
    END CATCH
END
GO

/*==============================================================================
  sp_GetTeacherScheduleStats

  Column names kept: TotalClasses, TotalSubjects, TotalClassesAssigned,
  DaysInWeek, EarliestClass, LatestClass, TotalMinutesPerWeek
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherScheduleStats
    @SchoolId   INT,
    @TeacherId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS TotalClasses,
           COUNT(DISTINCT SubjectId) AS TotalSubjects,
           COUNT(DISTINCT ClassId) AS TotalClassesAssigned,
           COUNT(DISTINCT DayOfWeek) AS DaysInWeek,
           MIN(StartTime) AS EarliestClass,
           MAX(EndTime) AS LatestClass,
           ISNULL(SUM(DATEDIFF(MINUTE, StartTime, EndTime)), 0) AS TotalMinutesPerWeek
    FROM dbo.TeacherSchedule
    WHERE SchoolId = @SchoolId
      AND TeacherId = @TeacherId
      AND IsActive = 1;
END
GO

/*==============================================================================
  sp_GetClassSchedule -- the timetable from the class's side.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassSchedule
    @SchoolId   INT,
    @ClassId    INT,
    @DayOfWeek  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ts.Id,
           ts.DayOfWeek,
           dbo.fn_DayName(ts.DayOfWeek) AS DayName,
           ts.StartTime,
           ts.EndTime,
           FORMAT(CAST(ts.StartTime AS DATETIME), 'hh:mm tt') AS StartTimeFormatted,
           FORMAT(CAST(ts.EndTime AS DATETIME), 'hh:mm tt') AS EndTimeFormatted,
           ts.Room,
           s.Id AS SubjectId,
           s.SubjectName,
           s.SubjectCode,
           t.Id AS TeacherId,
           t.EmployeeId,
           CONCAT(u.FirstName, ' ', u.LastName) AS TeacherName,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section
    FROM dbo.TeacherSchedule AS ts
    INNER JOIN dbo.Subjects AS s ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    INNER JOIN dbo.Classes  AS c ON c.SchoolId = ts.SchoolId AND c.Id = ts.ClassId
    INNER JOIN dbo.Teachers AS t ON t.SchoolId = ts.SchoolId AND t.Id = ts.TeacherId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId  AND u.Id = t.UserId
    WHERE ts.SchoolId = @SchoolId
      AND ts.ClassId = @ClassId
      AND (@DayOfWeek IS NULL OR ts.DayOfWeek = @DayOfWeek)
      AND ts.IsActive = 1
    ORDER BY ts.DayOfWeek, ts.StartTime;
END
GO

PRINT '=== 12_Procs_Schedule.sql complete ===';
GO

SET NOEXEC OFF;
GO
