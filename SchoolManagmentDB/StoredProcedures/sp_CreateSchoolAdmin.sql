/*==============================================================================
  StoredProcedure : dbo.sp_CreateSchoolAdmin
  Extracted from: 03_Procs_Platform.sql
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
  sp_CreateSchoolAdmin -- add a further Admin to an existing school.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateSchoolAdmin
    @SchoolId       INT,
    @Email          NVARCHAR(100),
    @PasswordHash   NVARCHAR(255),
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Username       NVARCHAR(80) = NULL,
    @CreatedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        /* Auto-name as CODE_ADMIN2, _ADMIN3, ... so the first admin keeps the
           plain CODE_ADMIN username. */
        IF NULLIF(LTRIM(RTRIM(ISNULL(@Username, N''))), N'') IS NULL
        BEGIN
            DECLARE @n INT = 2;
            SET @Username = @Code + N'_ADMIN2';
            WHILE EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username) AND @n < 100
            BEGIN
                SET @n = @n + 1;
                SET @Username = @Code + N'_ADMIN' + CAST(@n AS NVARCHAR(3));
            END
        END
        ELSE
        BEGIN
            /* An explicit username still has to carry the school prefix, or a
               later school could not create the same name. */
            SET @Username = dbo.fn_SanitizeCode(@Username);
            IF @Username NOT LIKE @Code + N'[_]%' SET @Username = @Code + N'_' + @Username;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            SELECT 'Error: Username ''' + @Username + ''' already exists.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: A user with this email already exists in this school.' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId     = @SchoolId,
            @Username     = @Username,
            @Email        = @Email,
            @PasswordHash = @PasswordHash,
            @RoleId       = 2,              -- Admin; see Roles seed in 01_Schema.sql
            @FirstName    = @FirstName,
            @LastName     = @LastName,
            @PhoneNumber  = @PhoneNumber,
            @ActorUserId  = @CreatedByUserId,
            @UserId       = @UserId OUTPUT,
            @PersonId     = @PersonId OUTPUT;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @CreatedByUserId,
            @Action = 'Admin.Create', @EntityType = 'User', @EntityId = @UserId,
            @Details = @Username;

        SELECT 'Success' AS Result, @UserId AS UserId, @Username AS Username;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS NVARCHAR(80)) AS Username;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
