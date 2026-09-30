/*==============================================================================
  StoredProcedure : dbo.sp_CreateUserAccount
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

SET NOEXEC OFF;
GO
