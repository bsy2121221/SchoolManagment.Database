/*==============================================================================
  StoredProcedure : dbo.sp_UpdateUser
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
  sp_UpdateUser

  The email uniqueness check is now per school (UQ_Users_School_Email), so a
  parent with children at two schools can use the same address at both. The old
  global check rejected that.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateUser
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
    @UpdatedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Users
                        WHERE Id = @UserId AND SchoolId = @SchoolId AND IsActive = 1)
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        /* Users, Persons and Addresses in one transaction: a half-applied edit
           would show the new name against the old phone number. */
        BEGIN TRANSACTION;

        EXEC dbo.sp_UpdateUserIdentity
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
            @ActorUserId  = @UpdatedBy;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedBy,
            @Action = 'User.Update', @EntityType = 'User', @EntityId = @UserId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
