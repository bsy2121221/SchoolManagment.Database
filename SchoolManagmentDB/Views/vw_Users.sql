/*==============================================================================
  View : dbo.vw_Users
  Extracted from: 01_Schema.sql
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
  SECTION 8 -- COMPATIBILITY VIEW

  vw_Users presents a User, their Person and their primary Address as one flat
  row, using the exact column names Users had before the split. Every read-only
  procedure in 04..14 selects "FROM dbo.vw_Users AS u" where it used to say
  "FROM dbo.Users AS u", so no result-set column name changed and no DTO or React
  table had to be touched.

  READ ONLY. Do not write through this view -- INSERT/UPDATE against a multi-table
  view either fails or silently touches one table. Writers go to Users, Persons
  and Addresses directly, or through sp_UpsertPerson / sp_UpsertAddress.

  WHICH ADDRESS
    The primary one; failing that, the lowest-numbered active one. Deterministic
    because UX_Addresses_Person_Primary allows at most one primary per person.

  THE Address COLUMN
    Assembled from the parts with ', ' separators, skipping the NULLs. A row
    written from the old single-string API (everything in AddressLine1) therefore
    reads back byte-identical.
==============================================================================*/
CREATE VIEW dbo.vw_Users
AS
SELECT u.Id,
       u.SchoolId,
       u.PersonId,
       u.Username,
       u.Email,
       u.PasswordHash,
       p.FirstName,
       p.LastName,
       p.FirstName + N' ' + p.LastName        AS FullName,
       p.PhoneNumber,
       p.AlternatePhoneNumber,
       u.RoleId,
       r.RoleName                             AS Role,
       r.RoleCode,
       u.IsActive,
       u.RequirePasswordChange,
       p.ProfilePicture,
       p.ProfilePictureFileName,
       p.ProfilePictureContentType,
       p.ProfilePictureUploadDate,
       a.Id                                   AS AddressId,
       a.AddressType,
       a.AddressLine1,
       a.AddressLine2,
       a.Landmark,
       a.City,
       a.State,
       a.Country,
       a.PostalCode,
       /* STUFF drops the leading ', '; it returns NULL for an empty string, which
          is exactly right for a person with no address at all. */
       STUFF(ISNULL(N', ' + a.AddressLine1, N'')
           + ISNULL(N', ' + a.AddressLine2, N'')
           + ISNULL(N', ' + a.Landmark,     N'')
           + ISNULL(N', ' + a.City,         N'')
           + ISNULL(N', ' + a.State,        N'')
           + ISNULL(N', ' + a.PostalCode,   N'')
           + ISNULL(N', ' + a.Country,      N''),
             1, 2, N'')                       AS Address,
       u.LastLoginAt,
       u.CreatedBy,
       u.ModifiedBy,
       cb.Username                            AS CreatedByUsername,
       mb.Username                            AS ModifiedByUsername,
       u.CreatedAt,
       u.UpdatedAt
FROM dbo.Users AS u
INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
INNER JOIN dbo.Roles   AS r ON r.Id = u.RoleId
LEFT  JOIN dbo.Users   AS cb ON cb.Id = u.CreatedBy
LEFT  JOIN dbo.Users   AS mb ON mb.Id = u.ModifiedBy
OUTER APPLY (
    SELECT TOP (1) ad.*
    FROM dbo.Addresses AS ad
    WHERE ad.PersonId = u.PersonId
      AND ad.IsActive = 1
    ORDER BY ad.IsPrimary DESC, ad.Id
) AS a;
GO

SET NOEXEC OFF;
GO

