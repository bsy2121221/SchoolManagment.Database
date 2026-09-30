/*==============================================================================
  StoredProcedure : dbo.sp_UpdateClassStatus
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
  sp_UpdateClassStatus -- Returns: Result

  New. ClassRepository.UpdateClassStatusAsync has always called this, so
  PUT /api/Classes/{id}/status failed with "Could not find stored procedure".

  Suspending a class is not the same as deleting one, so the dependency checks in
  sp_DeleteClass deliberately do not apply: a class with students and a term of
  attendance behind it is exactly the kind you suspend rather than delete. What it
  does do is cascade to the timetable, the same way the delete does -- a suspended
  class must stop appearing on teachers' schedules, or the suspension is invisible
  where it matters most.

  Reactivation restores the class row only. Timetable and grade-entry rights are
  not brought back, because there is no record of which of them were already
  inactive before the suspension, and guessing would hand a teacher rights that
  had been withdrawn on purpose.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateClassStatus
    @SchoolId   INT,
    @ClassId    INT,
    @IsActive   BIT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @Current BIT;

        SELECT @Current = IsActive
        FROM dbo.Classes
        WHERE SchoolId = @SchoolId AND Id = @ClassId;

        IF @Current IS NULL
        BEGIN
            SELECT 'Error: Class not found' AS Result;
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

        UPDATE dbo.Classes
           SET IsActive = @IsActive, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ClassId;

        IF @IsActive = 0
        BEGIN
            UPDATE dbo.TeacherSchedule SET IsActive = 0
             WHERE SchoolId = @SchoolId AND ClassId = @ClassId;
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

SET NOEXEC OFF;
GO
