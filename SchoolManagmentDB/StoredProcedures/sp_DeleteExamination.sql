/*==============================================================================
  StoredProcedure : dbo.sp_DeleteExamination
  Extracted from: 10_Procs_Academics.sql
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
  sp_DeleteExamination -- soft delete; the results go with it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteExamination
    @SchoolId       INT,
    @ExaminationId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Examinations
                        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Deactivating the results too keeps sp_GetStudentResults from showing
           marks for an exam that no longer appears in any list. */
        UPDATE dbo.Results SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND ExaminationId = @ExaminationId;

        UPDATE dbo.Examinations SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

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
  ----------------------------------- RESULTS -----------------------------------
==============================================================================*/

SET NOEXEC OFF;
GO
