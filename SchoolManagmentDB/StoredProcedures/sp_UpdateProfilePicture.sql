/*==============================================================================
  StoredProcedure : dbo.sp_UpdateProfilePicture
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
  sp_UpdateProfilePicture -- Returns: Result

  @ProfilePicture NULL clears the picture, which is how the UI's "remove photo"
  action is expressed; the filename, content type and upload date are cleared
  with it instead of being left pointing at bytes that are gone.

  Writes dbo.Persons, resolved through Users.PersonId. @ModifiedBy defaults to
  @UserId because uploading your own photo is the normal case.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateProfilePicture
    @SchoolId       INT = NULL,
    @UserId         INT,
    @ProfilePicture VARBINARY(MAX),
    @FileName       NVARCHAR(255) = NULL,
    @ContentType    NVARCHAR(100) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @PersonId INT =
            (SELECT PersonId FROM dbo.Users
              WHERE Id = @UserId
                AND (@SchoolId IS NULL OR SchoolId = @SchoolId));

        IF @PersonId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        SET @ModifiedBy = ISNULL(@ModifiedBy, @UserId);

        UPDATE dbo.Persons
           SET ProfilePicture            = @ProfilePicture,
               ProfilePictureFileName    = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE @FileName END,
               ProfilePictureContentType = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE @ContentType END,
               ProfilePictureUploadDate  = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE GETDATE() END,
               ModifiedBy                = @ModifiedBy,
               UpdatedAt                 = GETDATE()
         WHERE Id = @PersonId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
