/*==============================================================================
  StoredProcedure : dbo.sp_GetProfilePicture
  Extracted from: 14_Procs_Dashboard.sql
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
  sp_GetProfilePicture

  Returns: ProfilePicture, ProfilePictureFileName, ProfilePictureContentType,
           ProfilePictureUploadDate

  Keyed on Users.Id, which the API takes from the token rather than from the
  request body. @SchoolId is an optional extra guard, and must stay optional so
  a SuperAdmin can fetch their own.

  The bytes live on dbo.Persons now -- a photograph is a property of the human,
  not of their login. Still addressed by user id, so the API did not change.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetProfilePicture
    @SchoolId   INT = NULL,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProfilePicture,
           p.ProfilePictureFileName,
           p.ProfilePictureContentType,
           p.ProfilePictureUploadDate
    FROM dbo.Users AS u
    INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
    WHERE u.Id = @UserId
      AND (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
END
GO

SET NOEXEC OFF;
GO
