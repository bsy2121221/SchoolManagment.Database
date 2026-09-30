/*==============================================================================
  StoredProcedure : dbo.sp_GetAllStudents
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
  sp_GetAllStudents -- NEW. The paged list behind GET /api/Students.

  Columns are exactly StudentDTO's, plus SchoolId. The three new read procedures
  below repeat this column list rather than sharing a view, because a view would
  have to live in 01_Schema.sql -- and that script is the create-everything one,
  so shipping a change to it means re-running the whole database.

  @IsActive is a filter, not a fixed predicate. Deactivated students have to be
  reachable: sp_DeleteStudent is a soft delete, and a school looking for a
  student who left last year is looking for exactly those rows.

  Filtering is on Students.IsActive alone. sp_DeleteStudent deactivates the
  Users row with it, so adding "AND u.IsActive = 1" would only ever hide a row
  whose account was disabled by hand -- and hiding it is what makes a student
  impossible to find or reactivate.

  Returns: the page, then a single TotalCount row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllStudents
    @SchoolId   INT,
    @ClassId    INT           = NULL,
    @IsActive   BIT           = NULL,   -- NULL = both
    @SearchTerm NVARCHAR(100) = NULL,
    @Page       INT           = 1,
    @PageSize   INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* Defensive, not decorative: page 0 would make OFFSET negative and raise. */
    IF @Page IS NULL OR @Page < 1 SET @Page = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 100 SET @PageSize = 100;   -- mirrors Constants.Settings.MaxPageSize

    /* A cleared search box posts ?searchTerm= rather than dropping the
       parameter, and '%%' would match every row including the empty ones. */
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');

    /* LIKE metacharacters typed into a search box stand for themselves. Escape
       the bracket first, or the escapes added for % and _ get escaped in turn. */
    DECLARE @Pattern NVARCHAR(320) =
        CASE WHEN @SearchTerm IS NULL THEN NULL
             ELSE N'%' + REPLACE(REPLACE(REPLACE(@SearchTerm, N'[', N'[[]'),
                                         N'%', N'[%]'), N'_', N'[_]') + N'%'
        END;

    SELECT s.Id,
           s.UserId,
           s.StudentId,
           u.Username,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.ClassId,
           c.ClassName,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           u.Address,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@Pattern IS NULL
           OR u.FirstName LIKE @Pattern
           OR u.LastName LIKE @Pattern
           OR u.FirstName + N' ' + u.LastName LIKE @Pattern
           OR u.Email LIKE @Pattern
           OR u.Username LIKE @Pattern
           OR s.StudentId LIKE @Pattern
           OR s.RollNumber LIKE @Pattern)
    /* Grade and RollNumber are both NVARCHAR, so '10' sorts before '2' as text.
       TRY_CONVERT first puts each in the order a person reads a register in; the
       text key breaks ties for the non-numeric ones ('KG', '12A'). */
    ORDER BY TRY_CONVERT(INT, c.Grade), c.Grade, c.Section,
             TRY_CONVERT(INT, s.RollNumber), s.RollNumber,
             u.FirstName, u.LastName
    OFFSET (@Page - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    SELECT COUNT(*) AS TotalCount
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@Pattern IS NULL
           OR u.FirstName LIKE @Pattern
           OR u.LastName LIKE @Pattern
           OR u.FirstName + N' ' + u.LastName LIKE @Pattern
           OR u.Email LIKE @Pattern
           OR u.Username LIKE @Pattern
           OR s.StudentId LIKE @Pattern
           OR s.RollNumber LIKE @Pattern);
END
GO

SET NOEXEC OFF;
GO
