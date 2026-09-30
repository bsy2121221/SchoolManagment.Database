/*==============================================================================
  StoredProcedure : dbo.sp_GetUserDetails
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
  sp_GetUserDetails -- one row, with the role-specific columns filled in.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserDetails
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

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
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           u.RequirePasswordChange,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,

           -- Student
           CASE WHEN u.RoleId = 4 THEN s.RollNumber    END AS RollNumber,
           CASE WHEN u.RoleId = 4 THEN s.DateOfBirth   END AS DateOfBirth,
           CASE WHEN u.RoleId = 4 THEN s.FatherName    END AS FatherName,
           CASE WHEN u.RoleId = 4 THEN s.MotherName    END AS MotherName,
           CASE WHEN u.RoleId = 4 THEN s.BloodGroup    END AS BloodGroup,
           CASE WHEN u.RoleId = 4 THEN s.AdmissionDate END AS AdmissionDate,
           CASE WHEN u.RoleId = 4 THEN c.ClassName     END AS ClassName,
           CASE WHEN u.RoleId = 4 THEN c.Grade         END AS Grade,
           CASE WHEN u.RoleId = 4 THEN c.Section       END AS Section,

           -- Teacher
           CASE WHEN u.RoleId = 3 THEN t.Subject       END AS Subject,
           CASE WHEN u.RoleId = 3 THEN t.Qualification END AS Qualification,
           CASE WHEN u.RoleId = 3 THEN t.Experience    END AS Experience,
           CASE WHEN u.RoleId = 3 THEN t.Salary        END AS Salary,
           CASE WHEN u.RoleId = 3 THEN t.JoinDate      END AS JoinDate,

           -- Parent
           CASE WHEN u.RoleId = 5 THEN p.Occupation    END AS Occupation,
           CASE WHEN u.RoleId = 5 THEN p.AnnualIncome  END AS AnnualIncome,

           u.SchoolId
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id AND u.RoleId = 4
    LEFT JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id AND u.RoleId = 3
    LEFT JOIN dbo.Parents  AS p ON p.SchoolId = u.SchoolId AND p.UserId = u.Id AND u.RoleId = 5
    WHERE u.Id = @UserId
      AND u.SchoolId = @SchoolId
      AND u.IsActive = 1;

    /* Second set: the caller's own permission grid, so the profile screen can
       render what this user is allowed to do without a second request. */
    EXEC dbo.sp_GetUserPermissions @UserId = @UserId;
END
GO

SET NOEXEC OFF;
GO
