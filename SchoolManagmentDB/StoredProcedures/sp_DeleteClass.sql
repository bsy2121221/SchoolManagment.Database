/*==============================================================================
  StoredProcedure : dbo.sp_DeleteClass
  Extracted from: 08_Procs_Classes.sql
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

SET NOEXEC OFF;
GO
