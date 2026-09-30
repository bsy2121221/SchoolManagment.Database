/*==============================================================================
  StoredProcedure : dbo.sp_CreateUser
  Extracted from: 04_Procs_Auth.sql
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
  sp_CreateUser -- generic user insert (Admin / Parent; students and teachers
  go through their own registration procedures so they get generated ids).

  @Username is prefixed with the school code if the caller did not do it, so a
  hand-typed name in one school cannot block the same name in another.

  @RoleId is the new INT key; @Role still accepts a role name or code so an older
  caller keeps working. One of the two is required.

  Returns: Result, UserId, PersonId, Username
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateUser
    @SchoolId       INT,
    @Username       NVARCHAR(80),
    @Email          NVARCHAR(100),
    @PasswordHash   NVARCHAR(255),
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Role           NVARCHAR(20) = NULL,
    @RoleId         INT = NULL,
    @RequirePasswordChange BIT = 0,
    @CreatedBy      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        DECLARE @ResolvedRoleId INT;
        EXEC dbo.sp_ResolveRole @RoleId = @RoleId, @Role = @Role,
                                @ResolvedRoleId = @ResolvedRoleId OUTPUT;

        IF @ResolvedRoleId = 1
        BEGIN
            SELECT 'Error: SuperAdmin accounts cannot be created through this procedure.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS PersonId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        SET @Username = LTRIM(RTRIM(ISNULL(@Username, N'')));
        IF @Username = N''
        BEGIN
            SELECT 'Error: Username is required.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS PersonId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        IF @Username NOT LIKE @Code + N'[_]%'
            SET @Username = @Code + N'_' + dbo.fn_SanitizeCode(@Username);

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            SELECT 'Error: Username ''' + @Username + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS PersonId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: A user with this email already exists in this school.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS PersonId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        DECLARE @UserId INT, @PersonId INT;

        /* One transaction across Persons + Users + Addresses: a user without the
           person row behind it would violate FK_Users_Person and, worse, a person
           without a user would be an orphan nothing ever cleans up. */
        BEGIN TRANSACTION;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @PasswordHash,
            @RoleId                = @ResolvedRoleId,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = @RequirePasswordChange,
            @ActorUserId           = @CreatedBy,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @CreatedBy,
            @Action = 'User.Create', @EntityType = 'User', @EntityId = @UserId,
            @Details = @Username;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @UserId AS UserId, @PersonId AS PersonId,
               @Username AS Username;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS PersonId,
               CAST(NULL AS NVARCHAR(80)) AS Username;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
