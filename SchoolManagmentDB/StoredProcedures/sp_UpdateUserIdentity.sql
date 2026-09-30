/*==============================================================================
  StoredProcedure : dbo.sp_UpdateUserIdentity
  Extracted from: 02_Functions.sql
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
  sp_UpdateUserIdentity -- the mirror of sp_CreateUserAccount for edits.

  Email lives on Users, the names and phone live on Persons, the address lives on
  Addresses. Every "update this person's profile" procedure needs all three, so
  the fan-out happens once here.

  THROWs on failure; callers own the transaction and the shaped result row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateUserIdentity
    @SchoolId       INT,
    @UserId         INT,
    @FirstName      NVARCHAR(50)    = NULL,
    @LastName       NVARCHAR(50)    = NULL,
    @Email          NVARCHAR(100)   = NULL,
    @PhoneNumber    NVARCHAR(15)    = NULL,
    @Address        NVARCHAR(255)   = NULL,
    @AddressLine1   NVARCHAR(255)   = NULL,
    @AddressLine2   NVARCHAR(255)   = NULL,
    @City           NVARCHAR(80)    = NULL,
    @State          NVARCHAR(80)    = NULL,
    @Country        NVARCHAR(80)    = NULL,
    @PostalCode     NVARCHAR(20)    = NULL,
    @ActorUserId    INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PersonId INT;

    SELECT @PersonId = PersonId
    FROM dbo.Users
    WHERE Id = @UserId
      AND (SchoolId = @SchoolId OR (SchoolId IS NULL AND @SchoolId IS NULL));

    IF @PersonId IS NULL THROW 51040, 'User not found in this school.', 1;

    SET @Email = NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'');

    IF @Email IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE Email = @Email
                      AND Id <> @UserId
                      AND (SchoolId = @SchoolId OR (SchoolId IS NULL AND @SchoolId IS NULL)))
        BEGIN
            THROW 51041, 'Email already exists.', 1;
        END

        UPDATE dbo.Users
           SET Email      = @Email,
               ModifiedBy = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE Id = @UserId;
    END
    ELSE
    BEGIN
        /* Still stamp the account row: an edit happened, even if only to the
           person or the address. */
        UPDATE dbo.Users
           SET ModifiedBy = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE Id = @UserId;
    END

    EXEC dbo.sp_UpsertPerson
        @SchoolId    = @SchoolId,
        @FirstName   = @FirstName,
        @LastName    = @LastName,
        @PhoneNumber = @PhoneNumber,
        @ActorUserId = @ActorUserId,
        @PersonId    = @PersonId OUTPUT;

    /* Only touch the address when the caller said something about it. All-NULL
       means "not part of this edit"; an explicit empty string clears it. */
    IF @Address IS NOT NULL OR @AddressLine1 IS NOT NULL OR @AddressLine2 IS NOT NULL
    OR @City IS NOT NULL OR @State IS NOT NULL OR @Country IS NOT NULL
    OR @PostalCode IS NOT NULL
        EXEC dbo.sp_UpsertAddress
            @SchoolId     = @SchoolId,
            @PersonId     = @PersonId,
            @AddressType  = N'Permanent',
            @Address      = @Address,
            @AddressLine1 = @AddressLine1,
            @AddressLine2 = @AddressLine2,
            @City         = @City,
            @State        = @State,
            @Country      = @Country,
            @PostalCode   = @PostalCode,
            @IsPrimary    = 1,
            @ActorUserId  = @ActorUserId;
END
GO

SET NOEXEC OFF;
GO
