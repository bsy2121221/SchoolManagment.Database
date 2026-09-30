/*==============================================================================
  StoredProcedure : dbo.sp_GetAllUsers
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
  sp_GetAllUsers -- the paged, filtered user list.

  TWO RESULT SETS: the page, then the total row count. UserRepository already
  called it with @IsActive / @SearchTerm / @Page / @PageSize and read two sets via
  QueryMultipleAsync, but the procedure only took @SchoolId and @Role and returned
  one -- so paging silently did nothing and the total was always 0. The signature
  matches the caller now.

  @IsActive NULL returns active and inactive users together; the old procedure
  hard-coded IsActive = 1 and gave the admin no way to see a deactivated account.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllUsers
    @SchoolId   INT,
    @Role       NVARCHAR(50) = NULL,
    @RoleId     INT = NULL,
    @IsActive   BIT = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @Page       INT = 1,
    @PageSize   INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SET @Page       = CASE WHEN ISNULL(@Page, 1) < 1 THEN 1 ELSE @Page END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 20) BETWEEN 1 AND 500 THEN @PageSize ELSE 20 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');
    SET @RoleId     = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    DECLARE @Offset INT = (@Page - 1) * @PageSize;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.FullName,
           u.PhoneNumber,
           u.AlternatePhoneNumber,
           u.Address,
           u.AddressId,
           u.AddressType,
           u.AddressLine1,
           u.AddressLine2,
           u.Landmark,
           u.City,
           u.State,
           u.Country,
           u.PostalCode,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           /* The bytes themselves are never sent with a list -- the client asks
              for them one at a time from GET /users/{id}/profile-picture. This
              flag is what tells it whether that request is worth making. */
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
    WHERE u.SchoolId = @SchoolId
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR u.FirstName LIKE '%' + @SearchTerm + '%'
           OR u.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%')
    ORDER BY u.CreatedAt DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    /* Counted off Users alone: the view's joins cannot change the row count, and
       counting the base table keeps this off the address OUTER APPLY. */
    SELECT COUNT(*) AS TotalCount
    FROM dbo.Users AS u
    INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
    WHERE u.SchoolId = @SchoolId
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR p.FirstName LIKE '%' + @SearchTerm + '%'
           OR p.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%');
END
GO

SET NOEXEC OFF;
GO
