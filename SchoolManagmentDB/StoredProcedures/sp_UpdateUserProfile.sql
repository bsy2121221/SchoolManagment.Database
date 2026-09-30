/*==============================================================================
  StoredProcedure : dbo.sp_UpdateUserProfile
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
  sp_UpdateUserProfile -- what UserRepository.UpdateUserAsync actually calls.

  The repository has always named this procedure; it was never defined, so every
  profile edit failed. It is a thin pass-through to sp_UpdateUser rather than a
  copy, so the two cannot drift apart.

  @ModifiedBy is the name the C# side passes for the acting user.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateUserProfile
    @SchoolId       INT,
    @UserId         INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @AddressLine1   NVARCHAR(255) = NULL,
    @AddressLine2   NVARCHAR(255) = NULL,
    @City           NVARCHAR(80) = NULL,
    @State          NVARCHAR(80) = NULL,
    @Country        NVARCHAR(80) = NULL,
    @PostalCode     NVARCHAR(20) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_UpdateUser
        @SchoolId     = @SchoolId,
        @UserId       = @UserId,
        @FirstName    = @FirstName,
        @LastName     = @LastName,
        @Email        = @Email,
        @PhoneNumber  = @PhoneNumber,
        @Address      = @Address,
        @AddressLine1 = @AddressLine1,
        @AddressLine2 = @AddressLine2,
        @City         = @City,
        @State        = @State,
        @Country      = @Country,
        @PostalCode   = @PostalCode,
        @UpdatedBy    = @ModifiedBy;
END
GO

SET NOEXEC OFF;
GO
