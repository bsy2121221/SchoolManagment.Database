/*==============================================================================
  StoredProcedure : dbo.sp_CreateOrUpdateExamination
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
  sp_CreateOrUpdateExamination

  Returns: ExaminationId, Result, Operation

  The match key is (ExamName, ExamType, ClassId, SubjectId) -- not the Id, which
  this procedure never takes. Two consequences the UI has to be built around,
  because neither is discoverable from the endpoint:

    * The four key fields cannot be changed. Sending the same exam with a new
      name creates a second exam and leaves the first one standing; the marks
      stay on the original.
    * Only ExamDate, MaxMarks, PassingMarks and Duration are ever updated.

  Operation is new, and it exists because the caller could not tell a create from
  an update. ExaminationsController used to answer that by re-reading the exam
  afterwards and returning 201 when the read came back empty -- so 201 Created
  fired only when the row it had just written could not be found, i.e. only on
  breakage, and a genuine create reported 200. The procedure is the only place
  that knows which branch ran, so it now says so.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateOrUpdateExamination
    @SchoolId       INT,
    @ExamName       NVARCHAR(100),
    @ExamType       NVARCHAR(50),
    @ClassId        INT,
    @SubjectId      INT,
    @ExamDate       DATE,
    @MaxMarks       INT,
    @PassingMarks   INT,
    @Duration       INT = NULL,
    @CreatedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Class not found in this school' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Subject not found in this school' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        IF @MaxMarks IS NULL OR @MaxMarks <= 0 OR @PassingMarks < 0 OR @PassingMarks > @MaxMarks
        BEGIN
            SELECT 0 AS ExaminationId, 'Error: Passing marks must be between 0 and max marks' AS Result,
                   CAST(NULL AS NVARCHAR(10)) AS Operation;
            RETURN;
        END

        DECLARE @ExaminationId INT = (SELECT Id FROM dbo.Examinations
                                       WHERE SchoolId = @SchoolId
                                         AND ExamName = @ExamName
                                         AND ExamType = @ExamType
                                         AND ClassId = @ClassId
                                         AND SubjectId = @SubjectId
                                         AND IsActive = 1);

        DECLARE @Operation NVARCHAR(10);

        IF @ExaminationId IS NOT NULL
        BEGIN
            /* Lowering MaxMarks under an already-entered score would leave marks
               that no longer make sense on the report card. */
            IF EXISTS (SELECT 1 FROM dbo.Results
                        WHERE SchoolId = @SchoolId AND ExaminationId = @ExaminationId
                          AND IsActive = 1 AND ObtainedMarks > @MaxMarks)
            BEGIN
                SELECT @ExaminationId AS ExaminationId,
                       'Error: Some entered marks exceed the new maximum' AS Result,
                       CAST(NULL AS NVARCHAR(10)) AS Operation;
                RETURN;
            END

            UPDATE dbo.Examinations
               SET ExamDate     = @ExamDate,
                   MaxMarks     = @MaxMarks,
                   PassingMarks = @PassingMarks,
                   Duration     = @Duration,
                   UpdatedAt    = GETDATE()
             WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

            SET @Operation = 'Updated';

            /* The create branch logged and this one did not, so rescheduling an
               exam or moving its pass mark left no trace at all. */
            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @CreatedBy,
                @Action = 'Examination.Update', @EntityType = 'Examination',
                @EntityId = @ExaminationId, @Details = @ExamName;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.Examinations (SchoolId, ExamName, ExamType, ClassId, SubjectId,
                                          ExamDate, MaxMarks, PassingMarks, Duration)
            VALUES (@SchoolId, @ExamName, @ExamType, @ClassId, @SubjectId,
                    @ExamDate, @MaxMarks, @PassingMarks, @Duration);

            SET @ExaminationId = CAST(SCOPE_IDENTITY() AS INT);
            SET @Operation = 'Created';

            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @CreatedBy,
                @Action = 'Examination.Create', @EntityType = 'Examination',
                @EntityId = @ExaminationId, @Details = @ExamName;
        END

        SELECT @ExaminationId AS ExaminationId, 'Success' AS Result, @Operation AS Operation;
    END TRY
    BEGIN CATCH
        SELECT 0 AS ExaminationId, 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS NVARCHAR(10)) AS Operation;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
