/*==============================================================================
  StoredProcedure : dbo.sp_GetSubjects
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
  sp_GetSubjects

  The unpaged, active-only list. This is what SubjectRepository's
  GetSubjectsByGradeAsync now calls -- it was asking for sp_GetSubjectsByGrade,
  which does not exist, when a procedure taking exactly (@SchoolId, @Grade) and
  returning exactly that grade's live subjects was already deployed.

  CreatedAt and UpdatedAt added: both are on SubjectDTO, and a column the
  procedure does not select comes back as 0001-01-01, which a client cannot tell
  from a real timestamp. One result set and the same row count as before, so
  16_Verify.sql's @@ROWCOUNT assertion still holds.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSubjects
    @SchoolId   INT,
    @Grade      NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* A cleared filter box posts ?grade= rather than dropping the parameter, and
       matching on '' would return nothing. */
    IF @Grade = N'' SET @Grade = NULL;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive, CreatedAt, UpdatedAt, SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND IsActive = 1
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName;
END
GO

SET NOEXEC OFF;
GO
