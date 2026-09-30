/*==============================================================================
  StoredProcedure : dbo.sp_PromoteStudent
  Extracted from: 06_Procs_Students.sql
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
  sp_PromoteStudent -- NEW. Move a student into another class.

  "Promote" is the only way a student changes class, which is why it also covers
  a sideways move between sections. Three things have to happen together:

  ROLL NUMBER
    Roll numbers are unique per class (UX_Students_School_Class_Roll), so
    carrying the old one across can collide with a student already in the target
    class. A fresh number is claimed from the target class's own counter, the
    same 'Roll:<ClassId>' sequence sp_RegisterStudent uses. The loop guards
    against a counter that has fallen behind rows inserted by hand.

  CAPACITY
    Checked against the target class's MaxStudents, exactly as registration does.
    Promoting into a full class is how a class quietly ends up over capacity.

  SUBJECTS
    Subjects belong to a grade. A student moving from grade 9 to grade 10 keeps
    their grade-9 enrolments otherwise, and every subject list, examination and
    report for them stays a year behind. Links to subjects that do not belong to
    the new class's grade are deactivated; the new grade's subjects are not
    assigned automatically, because which of them this student takes is a choice
    (POST /students/{id}/subjects makes it).

  @AcademicYear is recorded in the audit trail and nowhere else: this database
  has no promotion-history table, and inventing one here would be a schema
  change in a file that only holds procedures.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PromoteStudent
    @SchoolId          INT,
    @StudentId         INT,              -- Students.Id
    @NewClassId        INT,
    @AcademicYear      INT,
    @PerformedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @OldClassId INT, @StudentNumber NVARCHAR(40);

        SELECT @OldClassId = ClassId, @StudentNumber = StudentId
        FROM dbo.Students
        WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1;

        IF @StudentNumber IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF @AcademicYear IS NULL OR @AcademicYear < 2000 OR @AcademicYear > 2100
        BEGIN
            SELECT 'Error: Academic year must be a four-digit year' AS Result;
            RETURN;
        END

        DECLARE @NewClassName NVARCHAR(50), @NewGrade NVARCHAR(10), @MaxStudents INT;

        SELECT @NewClassName = ClassName, @NewGrade = Grade, @MaxStudents = MaxStudents
        FROM dbo.Classes
        WHERE SchoolId = @SchoolId AND Id = @NewClassId AND IsActive = 1;

        IF @NewClassName IS NULL
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result;
            RETURN;
        END

        IF @OldClassId = @NewClassId
        BEGIN
            SELECT 'Error: Student is already in ' + @NewClassName AS Result;
            RETURN;
        END

        IF (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @SchoolId AND ClassId = @NewClassId AND IsActive = 1) >= @MaxStudents
        BEGIN
            SELECT 'Error: Class ' + @NewClassName + ' is full' AS Result;
            RETURN;
        END

        DECLARE @OldClassName NVARCHAR(50) = (SELECT ClassName FROM dbo.Classes
                                               WHERE SchoolId = @SchoolId AND Id = @OldClassId);

        BEGIN TRANSACTION;

        DECLARE @Seq INT,
                @Candidate NVARCHAR(10),
                @NewRoll NVARCHAR(10) = NULL,
                @Attempts INT = 0;
        DECLARE @SeqName NVARCHAR(50) = N'Roll:' + CAST(@NewClassId AS NVARCHAR(10));

        WHILE @NewRoll IS NULL AND @Attempts < 100
        BEGIN
            SET @Attempts += 1;

            EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = @SeqName,
                                     @NextValue = @Seq OUTPUT;

            /* Same three-digit shape sp_RegisterStudent produces, widening past
               999 rather than truncating. */
            SET @Candidate = RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)),
                                   CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END);

            IF NOT EXISTS (SELECT 1 FROM dbo.Students
                            WHERE SchoolId = @SchoolId AND ClassId = @NewClassId
                              AND RollNumber = @Candidate)
                SET @NewRoll = @Candidate;
        END

        IF @NewRoll IS NULL
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Could not allocate a free roll number in ' + @NewClassName AS Result;
            RETURN;
        END

        UPDATE dbo.Students
           SET ClassId    = @NewClassId,
               RollNumber = @NewRoll,
               UpdatedAt  = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @StudentId;

        UPDATE ss
           SET ss.IsActive = 0
        FROM dbo.StudentSubjects AS ss
        INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
        WHERE ss.SchoolId = @SchoolId
          AND ss.StudentId = @StudentId
          AND ss.IsActive = 1
          AND sub.Grade <> @NewGrade;

        DECLARE @Details NVARCHAR(400) =
            CONCAT(@StudentNumber, ': ', ISNULL(@OldClassName, N'no class'), ' -> ', @NewClassName,
                   N', roll ', @NewRoll, N', academic year ', @AcademicYear);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Promote', @EntityType = 'Student', @EntityId = @StudentId,
            @Details = @Details;

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
