/*==============================================================================
  StoredProcedure : dbo.sp_MarkAttendanceBulk
  Extracted from: 09_Procs_Attendance.sql
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

SET NOEXEC OFF;
GO
