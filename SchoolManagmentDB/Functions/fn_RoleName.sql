/*==============================================================================
  Function : dbo.fn_RoleName
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
  fn_RoleName -- Roles.Id -> name, for messages and audit details.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_RoleName (@RoleId INT)
RETURNS NVARCHAR(50)
AS
BEGIN
    RETURN (SELECT RoleName FROM dbo.Roles WHERE Id = @RoleId);
END
GO

/*==============================================================================
  sp_ResolveRole -- normalise the "@RoleId or @Role" pair the write procedures
  accept, so callers on either the old string API or the new id API both work.

  @RoleId wins when both are supplied. Throws rather than returning a row,
  because every caller is inside a transaction that must not continue.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ResolveRole
    @RoleId         INT             = NULL,
    @Role           NVARCHAR(50)    = NULL,
    @ResolvedRoleId INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @ResolvedRoleId = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    IF @ResolvedRoleId IS NULL
    BEGIN
        THROW 51010, 'A role is required. Pass @RoleId, or @Role as a role name or code.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE Id = @ResolvedRoleId AND IsActive = 1)
    BEGIN
        THROW 51011, 'Role not found, or the role is inactive.', 1;
    END
END
GO

/*==============================================================================
  sp_UpsertPerson -- create or update the Persons row behind a user.

  @PersonId NULL  -> insert, and return the new id in @PersonId.
  @PersonId given -> update, but only if that person belongs to @SchoolId.

  NULL means "leave alone" on update, so a caller that only knows the phone
  number does not blank out the name. On insert, @FirstName / @LastName are
  required.

  @SchoolId is NULL for the platform SuperAdmin only; sp_AssertSchool is
  therefore skipped in that one case rather than failing the whole call.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpsertPerson
    @SchoolId               INT,
    @FirstName              NVARCHAR(50)    = NULL,
    @LastName               NVARCHAR(50)    = NULL,
    @PhoneNumber            NVARCHAR(15)    = NULL,
    @AlternatePhoneNumber   NVARCHAR(15)    = NULL,
    @ActorUserId            INT             = NULL,
    @PersonId               INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @SchoolId IS NOT NULL EXEC dbo.sp_AssertSchool @SchoolId;

    IF @PersonId IS NULL
    BEGIN
        IF NULLIF(LTRIM(RTRIM(ISNULL(@FirstName, N''))), N'') IS NULL
         OR NULLIF(LTRIM(RTRIM(ISNULL(@LastName,  N''))), N'') IS NULL
        BEGIN
            THROW 51020, 'First name and last name are required to create a person.', 1;
        END

        INSERT INTO dbo.Persons (SchoolId, FirstName, LastName, PhoneNumber,
                                 AlternatePhoneNumber, CreatedBy, ModifiedBy)
        VALUES (@SchoolId, LTRIM(RTRIM(@FirstName)), LTRIM(RTRIM(@LastName)), @PhoneNumber,
                @AlternatePhoneNumber, @ActorUserId, @ActorUserId);

        SET @PersonId = CAST(SCOPE_IDENTITY() AS INT);
        RETURN;
    END

    /* The SchoolId comparison has to tolerate NULL = NULL for the SuperAdmin. */
    IF NOT EXISTS (SELECT 1 FROM dbo.Persons
                    WHERE Id = @PersonId
                      AND (SchoolId = @SchoolId
                           OR (SchoolId IS NULL AND @SchoolId IS NULL)))
    BEGIN
        THROW 51021, 'Person not found in this school.', 1;
    END

    UPDATE dbo.Persons
       SET FirstName            = ISNULL(NULLIF(LTRIM(RTRIM(@FirstName)), N''), FirstName),
           LastName             = ISNULL(NULLIF(LTRIM(RTRIM(@LastName)),  N''), LastName),
           PhoneNumber          = ISNULL(@PhoneNumber,          PhoneNumber),
           AlternatePhoneNumber = ISNULL(@AlternatePhoneNumber, AlternatePhoneNumber),
           ModifiedBy           = ISNULL(@ActorUserId, ModifiedBy),
           UpdatedAt            = GETDATE()
     WHERE Id = @PersonId;
END
GO

/*==============================================================================
  sp_UpsertAddress -- create or replace one typed address for a person.

  Keyed on (@PersonId, @AddressType) to match UQ_Addresses_Person_Type, so
  calling this twice with 'Permanent' updates rather than duplicates.

  @Address is the legacy single-string form. When the structured parameters are
  all NULL it is stored verbatim in AddressLine1, which is what makes
  vw_Users.Address read back exactly what the old API wrote.

  A blank address is a DELETE (deactivate), not an empty row: the old API cleared
  Users.Address by sending NULL, and that has to keep working.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpsertAddress
    @SchoolId       INT,
    @PersonId       INT,
    @AddressType    NVARCHAR(20)    = 'Permanent',
    @Address        NVARCHAR(255)   = NULL,   -- legacy single-line form
    @AddressLine1   NVARCHAR(255)   = NULL,
    @AddressLine2   NVARCHAR(255)   = NULL,
    @Landmark       NVARCHAR(100)   = NULL,
    @City           NVARCHAR(80)    = NULL,
    @State          NVARCHAR(80)    = NULL,
    @Country        NVARCHAR(80)    = NULL,
    @PostalCode     NVARCHAR(20)    = NULL,
    @IsPrimary      BIT             = 1,
    @ActorUserId    INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @AddressType = ISNULL(NULLIF(LTRIM(RTRIM(@AddressType)), N''), N'Permanent');
    SET @AddressLine1 = NULLIF(LTRIM(RTRIM(ISNULL(@AddressLine1, ISNULL(@Address, N'')))), N'');

    IF NOT EXISTS (SELECT 1 FROM dbo.Persons
                    WHERE Id = @PersonId
                      AND (SchoolId = @SchoolId
                           OR (SchoolId IS NULL AND @SchoolId IS NULL)))
    BEGIN
        THROW 51022, 'Person not found in this school.', 1;
    END

    /* Nothing to store: retire any existing address of this type. Deactivated
       rather than deleted so UQ_Addresses_Person_Type still guards the slot and
       the history survives; the filtered primary index only counts IsPrimary,
       so IsPrimary must be cleared too. */
    IF @AddressLine1 IS NULL
    BEGIN
        UPDATE dbo.Addresses
           SET IsActive   = 0,
               IsPrimary  = 0,
               ModifiedBy = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType = @AddressType;
        RETURN;
    END

    /* Only one row per person may be primary, so stand the others down first. */
    IF @IsPrimary = 1
        UPDATE dbo.Addresses
           SET IsPrimary = 0,
               UpdatedAt = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType <> @AddressType
           AND IsPrimary = 1;

    IF EXISTS (SELECT 1 FROM dbo.Addresses
                WHERE PersonId = @PersonId AND AddressType = @AddressType)
    BEGIN
        UPDATE dbo.Addresses
           SET AddressLine1 = @AddressLine1,
               AddressLine2 = @AddressLine2,
               Landmark     = @Landmark,
               City         = @City,
               State        = @State,
               Country      = @Country,
               PostalCode   = @PostalCode,
               IsPrimary    = @IsPrimary,
               IsActive     = 1,
               ModifiedBy   = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt    = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType = @AddressType;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.Addresses (SchoolId, PersonId, AddressType, AddressLine1, AddressLine2,
                                   Landmark, City, State, Country, PostalCode, IsPrimary,
                                   CreatedBy, ModifiedBy)
        VALUES (@SchoolId, @PersonId, @AddressType, @AddressLine1, @AddressLine2,
                @Landmark, @City, @State, @Country, @PostalCode, @IsPrimary,
                @ActorUserId, @ActorUserId);
    END
END
GO

/*==============================================================================
  sp_CreateUserAccount -- the single place a Users row is born.

  sp_CreateUser, sp_RegisterStudent, sp_RegisterTeacher, sp_CreateSchool and
  sp_CreateSchoolAdmin all funnel through here, so the person/address/user trio
  is always written the same way and the uniqueness messages stay consistent.

  Callers own the transaction. This procedure THROWs on any problem instead of
  returning an error row, so the caller's CATCH produces its own shaped result.

  Returns nothing; @UserId and @PersonId come back as OUTPUT parameters.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateUserAccount
    @SchoolId               INT,
    @Username               NVARCHAR(80),
    @Email                  NVARCHAR(100),
    @PasswordHash           NVARCHAR(255),
    @RoleId                 INT,
    @FirstName              NVARCHAR(50),
    @LastName               NVARCHAR(50),
    @PhoneNumber            NVARCHAR(15)    = NULL,
    @Address                NVARCHAR(255)   = NULL,
    @RequirePasswordChange  BIT             = 0,
    @IsActive               BIT             = 1,
    @ActorUserId            INT             = NULL,
    @UserId                 INT             OUTPUT,
    @PersonId               INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Username = NULLIF(LTRIM(RTRIM(ISNULL(@Username, N''))), N'');
    SET @Email    = NULLIF(LTRIM(RTRIM(ISNULL(@Email,    N''))), N'');

    IF @Username IS NULL THROW 51030, 'Username is required.', 1;
    IF @Email    IS NULL THROW 51031, 'Email is required.', 1;

    IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
    BEGIN
        DECLARE @m1 NVARCHAR(200) = N'Username ''' + @Username + N''' already exists.';
        THROW 51032, @m1, 1;
    END

    IF EXISTS (SELECT 1 FROM dbo.Users
                WHERE Email = @Email
                  AND (SchoolId = @SchoolId OR (SchoolId IS NULL AND @SchoolId IS NULL)))
    BEGIN
        THROW 51033, 'A user with this email already exists in this school.', 1;
    END

    SET @PersonId = NULL;

    EXEC dbo.sp_UpsertPerson
        @SchoolId    = @SchoolId,
        @FirstName   = @FirstName,
        @LastName    = @LastName,
        @PhoneNumber = @PhoneNumber,
        @ActorUserId = @ActorUserId,
        @PersonId    = @PersonId OUTPUT;

    INSERT INTO dbo.Users (SchoolId, PersonId, Username, Email, PasswordHash, RoleId,
                           IsActive, RequirePasswordChange, CreatedBy, ModifiedBy)
    VALUES (@SchoolId, @PersonId, @Username, @Email, @PasswordHash, @RoleId,
            @IsActive, @RequirePasswordChange, @ActorUserId, @ActorUserId);

    SET @UserId = CAST(SCOPE_IDENTITY() AS INT);

    /* Self-attribute when nobody else did -- true for the seeded SuperAdmin and
       for self-service registration, and better than a NULL that reads as
       "provenance unknown". */
    IF @ActorUserId IS NULL
    BEGIN
        UPDATE dbo.Users   SET CreatedBy = @UserId, ModifiedBy = @UserId WHERE Id = @UserId;
        UPDATE dbo.Persons SET CreatedBy = @UserId, ModifiedBy = @UserId WHERE Id = @PersonId;
    END

    IF NULLIF(LTRIM(RTRIM(ISNULL(@Address, N''))), N'') IS NOT NULL
        EXEC dbo.sp_UpsertAddress
            @SchoolId    = @SchoolId,
            @PersonId    = @PersonId,
            @AddressType = N'Permanent',
            @Address     = @Address,
            @IsPrimary   = 1,
            @ActorUserId = @UserId;
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

/*==============================================================================
  sp_LogAudit -- append an activity row.

  The activity feeds (sp_GetUserActivityLog, sp_GetProfileActivities) used to be
  reconstructed from CreatedAt columns because no audit table existed. They now
  read real events written here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LogAudit
    @SchoolId   INT = NULL,
    @UserId     INT = NULL,
    @Action     NVARCHAR(100),
    @EntityType NVARCHAR(50) = NULL,
    @EntityId   INT = NULL,
    @Details    NVARCHAR(1000) = NULL,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditLog (SchoolId, UserId, Action, EntityType, EntityId, Details, IpAddress)
    VALUES (@SchoolId, @UserId, @Action, @EntityType, @EntityId, @Details, @IpAddress);
END
GO

SET NOEXEC OFF;
GO
