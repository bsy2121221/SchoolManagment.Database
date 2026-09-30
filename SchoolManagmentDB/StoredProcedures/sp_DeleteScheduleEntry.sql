/*==============================================================================
  StoredProcedure : dbo.sp_DeleteScheduleEntry
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

SET NOEXEC OFF;
GO
