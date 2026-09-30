/*==============================================================================
  StoredProcedure : dbo.sp_GetSchools
  Extracted from: 03_Procs_Platform.sql
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
  sp_GetSchools -- tenant list with headline counts for the platform dashboard.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSchools
    @SearchTerm     NVARCHAR(100) = NULL,
    @IsActive       BIT = NULL,
    @PageNumber     INT = 1,
    @PageSize       INT = 50
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 50) BETWEEN 1 AND 500 THEN @PageSize ELSE 50 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');

    SELECT s.Id,
           s.SchoolCode,
           s.SchoolName,
           s.Subdomain,
           s.Address,
           s.City,
           s.State,
           s.Country,
           s.PostalCode,
           s.ContactEmail,
           s.ContactPhone,
           s.PrincipalName,
           s.LogoUrl,
           s.ThemeColor,
           s.AcademicYearStartMonth,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           ISNULL(cnt.TotalStudents, 0) AS TotalStudents,
           ISNULL(cnt.TotalTeachers, 0) AS TotalTeachers,
           ISNULL(cnt.TotalClasses,  0) AS TotalClasses,
           ISNULL(cnt.TotalUsers,    0) AS TotalUsers,
           COUNT(*) OVER () AS TotalCount
    FROM dbo.Schools AS s
    OUTER APPLY (
        SELECT (SELECT COUNT(*) FROM dbo.Students AS st WHERE st.SchoolId = s.Id AND st.IsActive = 1) AS TotalStudents,
               (SELECT COUNT(*) FROM dbo.Teachers AS te WHERE te.SchoolId = s.Id AND te.IsActive = 1) AS TotalTeachers,
               (SELECT COUNT(*) FROM dbo.Classes  AS cl WHERE cl.SchoolId = s.Id AND cl.IsActive = 1) AS TotalClasses,
               (SELECT COUNT(*) FROM dbo.Users    AS us WHERE us.SchoolId = s.Id AND us.IsActive = 1) AS TotalUsers
    ) AS cnt
    WHERE (@IsActive IS NULL OR s.IsActive = @IsActive)
      AND (@SearchTerm IS NULL
           OR s.SchoolName LIKE '%' + @SearchTerm + '%'
           OR s.SchoolCode LIKE '%' + @SearchTerm + '%'
           OR s.City       LIKE '%' + @SearchTerm + '%')
    ORDER BY s.SchoolName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

SET NOEXEC OFF;
GO
