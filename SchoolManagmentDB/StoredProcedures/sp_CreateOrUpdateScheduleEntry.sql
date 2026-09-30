/*==============================================================================
  StoredProcedure : dbo.sp_CreateOrUpdateScheduleEntry
  Extracted from: 12_Procs_Schedule.sql
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

SET NOEXEC OFF;
GO
