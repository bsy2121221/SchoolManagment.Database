/*==============================================================================
  StoredProcedure : dbo.sp_GetAllClasses
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
  sp_GetAllClasses -- Returns: the requested page, then the total row count.

  Took only @SchoolId while ClassRepository passed five parameters and read two
  result sets, so GET /api/Classes failed outright with "too many arguments
  specified". Filtering and paging were the API's documented contract
  (?grade=&isActive=&page=&pageSize=) and were simply never implemented here.

  @IsActive is a filter, not a fixed predicate: the list screen has an
  active/inactive/all toggle, and the old hardcoded IsActive = 1 made
  soft-deleted classes unreachable -- which matters because sp_CreateClass
  refuses a grade+section that a *deleted* class still occupies. Without a way
  to see them, that refusal is unexplainable.

  ClassTeacher and StudentCount were aliased to names ClassDTO does not have
  (it declares ClassTeacherName and TotalStudents), so both arrived empty. The
  same mistake was in sp_GetClassById.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllClasses
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

    /* Empty string treated as absent: a cleared filter box posts ?grade= rather
       than dropping the parameter, and matching on '' would return nothing. */
    IF @Grade = N'' SET @Grade = NULL;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           c.IsActive,
           c.CreatedAt,
           c.UpdatedAt,
           c.ClassTeacherId,
           CASE WHEN c.ClassTeacherId IS NOT NULL
                THEN u.FirstName + ' ' + u.LastName
                ELSE NULL END AS ClassTeacherName,
           COUNT(s.Id) AS TotalStudents,
           c.SchoolId
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = c.SchoolId AND t.Id = c.ClassTeacherId
    LEFT JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND (@Grade IS NULL OR c.Grade = @Grade)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive)
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents, c.IsActive,
             c.CreatedAt, c.UpdatedAt, c.ClassTeacherId, u.FirstName, u.LastName, c.SchoolId
    /* Grade is NVARCHAR, so '10' sorts before '2' as text. TRY_CONVERT first puts
       it in the order a person reads a class list in; the text key breaks ties for
       non-numeric grades such as 'KG', which convert to NULL. */
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Classes AS c
    WHERE c.SchoolId = @SchoolId
      AND (@Grade IS NULL OR c.Grade = @Grade)
      AND (@IsActive IS NULL OR c.IsActive = @IsActive);
END
GO

SET NOEXEC OFF;
GO
