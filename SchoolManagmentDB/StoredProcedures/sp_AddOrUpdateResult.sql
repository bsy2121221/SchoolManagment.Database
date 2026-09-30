/*==============================================================================
  StoredProcedure : dbo.sp_AddOrUpdateResult
  Extracted from: 10_Procs_Academics.sql
  Part of SchoolManagementDB structured layout.
==============================================================================*/
/*==============================================================================
  sp_AddOrUpdateResult

  @Grade is now optional: NULL means "work it out from this school's scale".

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AddOrUpdateResult
    @SchoolId       INT,
    @StudentId      INT,
    @ExaminationId  INT,
    @ObtainedMarks  INT,
    @Grade          NVARCHAR(5) = NULL,
    @Remarks        NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @ExamClassId INT, @MaxMarks INT;

        SELECT @ExamClassId = ClassId, @MaxMarks = MaxMarks
        FROM dbo.Examinations
        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1;

        IF @ExamClassId IS NULL
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result;
            RETURN;
        END

        /* The student must sit in the class the exam was set for. Nothing
           enforced this before, so a typo posted marks to another class. */
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND Id = @StudentId
                          AND ClassId = @ExamClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Student is not in the class this examination belongs to' AS Result;
            RETURN;
        END

        IF @ObtainedMarks < 0 OR @ObtainedMarks > @MaxMarks
        BEGIN
            SELECT 'Error: Marks must be between 0 and ' + CAST(@MaxMarks AS NVARCHAR(10)) AS Result;
            RETURN;
        END

        DECLARE @FinalGrade NVARCHAR(5) =
            COALESCE(NULLIF(@Grade, N''), dbo.fn_CalculateGrade(@SchoolId, @ObtainedMarks, @MaxMarks));

        MERGE dbo.Results WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId,
                      @ExaminationId AS ExaminationId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ExaminationId = src.ExaminationId
        WHEN MATCHED THEN
            UPDATE SET ObtainedMarks = @ObtainedMarks,
                       Grade         = @FinalGrade,
                       Remarks       = @Remarks,
                       IsActive      = 1,
                       UpdatedAt     = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ExaminationId, ObtainedMarks, Grade, Remarks)
            VALUES (src.SchoolId, src.StudentId, src.ExaminationId,
                    @ObtainedMarks, @FinalGrade, @Remarks);

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
