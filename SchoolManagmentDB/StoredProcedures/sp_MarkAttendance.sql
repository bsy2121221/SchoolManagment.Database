/*==============================================================================
  StoredProcedure : dbo.sp_MarkAttendance
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

SET NOEXEC OFF;
GO
