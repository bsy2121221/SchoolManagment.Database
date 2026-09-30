/*==============================================================================
  StoredProcedure : dbo.sp_PreviewStudentUsername
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
  sp_PreviewStudentUsername -- show the admin what will be generated.

  Uses sp_PeekSequence, NOT sp_NextSequence: a preview must not consume a
  number. The value is therefore advisory -- if two admins preview at once they
  see the same one, and whoever saves first gets it.

  Returns: GeneratedUsername, GeneratedStudentId, GeneratedRollNumber
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PreviewStudentUsername
    @SchoolId           INT,
    @ClassId            INT = NULL,
    @RegistrationYear   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);
    DECLARE @ClassName NVARCHAR(50) = (SELECT ClassName FROM dbo.Classes
                                        WHERE SchoolId = @SchoolId AND Id = @ClassId);

    SET @RegistrationYear = ISNULL(@RegistrationYear,
                                   dbo.fn_AcademicYear(@SchoolId, CAST(GETDATE() AS DATE)));

    DECLARE @SeqName NVARCHAR(50) =
        CASE WHEN @ClassId IS NULL THEN N'Student'
             ELSE N'Roll:' + CAST(@ClassId AS NVARCHAR(10)) END;

    DECLARE @Seq INT;
    EXEC dbo.sp_PeekSequence @SchoolId = @SchoolId, @SequenceName = @SeqName, @NextValue = @Seq OUTPUT;

    DECLARE @Label NVARCHAR(50) = ISNULL(@ClassName, N'GEN');

    SELECT dbo.fn_GenerateStudentUsername(@Code, @Label, @RegistrationYear, @Seq) AS GeneratedUsername,
           dbo.fn_GenerateStudentId(@Code, @Label, @RegistrationYear, @Seq) AS GeneratedStudentId,
           CASE WHEN @ClassId IS NULL THEN NULL
                ELSE RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END)
           END AS GeneratedRollNumber;
END
GO

SET NOEXEC OFF;
GO
