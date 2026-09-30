/*==============================================================================
  StoredProcedure : dbo.sp_DeleteProfilePicture
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
  sp_DeleteProfilePicture -- Returns: Result

  NEW. UserRepository.DeleteProfilePictureAsync has always called this name;
  nothing ever created it, so "remove photo" failed with "Could not find stored
  procedure". It is sp_UpdateProfilePicture with a NULL image, kept as its own
  entry point so the DELETE endpoint does not have to send a NULL VARBINARY(MAX).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteProfilePicture
    @SchoolId   INT = NULL,
    @UserId     INT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_UpdateProfilePicture
        @SchoolId       = @SchoolId,
        @UserId         = @UserId,
        @ProfilePicture = NULL,
        @FileName       = NULL,
        @ContentType    = NULL,
        @ModifiedBy     = @ModifiedBy;
END
GO

SET NOEXEC OFF;
GO
