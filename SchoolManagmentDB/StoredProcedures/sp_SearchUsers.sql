/*==============================================================================
  StoredProcedure : dbo.sp_SearchUsers
  Extracted from: 05_Procs_Users.sql
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
  sp_SearchUsers
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SearchUsers
    @SchoolId       INT,
    @SearchTerm     NVARCHAR(100) = NULL,
    @Role           NVARCHAR(50) = NULL,
    @RoleId         INT = NULL,
    @PageSize       INT = 50,
    @PageNumber     INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 50) BETWEEN 1 AND 500 THEN @PageSize ELSE 50 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');
    SET @RoleId     = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.FullName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.CreatedAt,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           COUNT(*) OVER () AS TotalCount
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
    WHERE u.SchoolId = @SchoolId
      AND u.IsActive = 1
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR u.FirstName LIKE '%' + @SearchTerm + '%'
           OR u.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%')
    ORDER BY u.CreatedAt DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

SET NOEXEC OFF;
GO
