/*==============================================================================
  StoredProcedure : dbo.sp_GetAllSubjects
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
  sp_GetAllSubjects -- NEW. Returns two result sets: the page, then TotalCount.

  The paged read behind GET /api/Subjects, shaped like sp_GetAllClasses because
  the repository, service and controller treat the two the same way.

  Unlike sp_GetSubjects this does not hardcode IsActive = 1: an administrator
  managing the subject list has to be able to see the deactivated ones, or a code
  held by a soft-deleted subject looks like sp_CreateSubject refusing for no
  reason.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSubjects
    @SchoolId   INT,
    @Grade      NVARCHAR(10) = NULL,
    @IsActive   BIT          = NULL,   -- NULL = both
    @Page       INT          = 1,
    @PageSize   INT          = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* Defensive, not decorative: page 0 would make OFFSET negative and raise. */
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 100 SET @PageSize = 100;   -- mirrors Constants.Settings.MaxPageSize

    IF @Grade = N'' SET @Grade = NULL;

    SELECT Id,
           SubjectName,
           SubjectCode,
           Grade,
           IsActive,
           CreatedAt,
           UpdatedAt,
           SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND (@IsActive IS NULL OR IsActive = @IsActive)
    /* Grade is NVARCHAR, so '10' sorts before '2' as text. TRY_CONVERT first puts
       it in the order a person reads the list in; the text key breaks ties for
       non-numeric grades such as 'KG', which convert to NULL. */
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND (@Grade IS NULL OR Grade = @Grade)
      AND (@IsActive IS NULL OR IsActive = @IsActive);
END
GO

SET NOEXEC OFF;
GO
