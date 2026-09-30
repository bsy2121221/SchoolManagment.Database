/*==============================================================================
  StoredProcedure : dbo.sp_RegisterParent
  Extracted from: 17_Procs_Parents.sql
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
  sp_RegisterParent

  Returns: Result, UserId, ParentId, Username

  The default password is the shared Temp@123 hash with RequirePasswordChange = 1,
  as for students and teachers. @PasswordHash is honoured when the caller supplies
  one, because ParentRegistrationDTO carries an optional Password -- hashing stays
  in C#, never here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RegisterParent
    @SchoolId           INT,
    @FirstName          NVARCHAR(50),
    @LastName           NVARCHAR(50),
    @Email              NVARCHAR(100),
    @PhoneNumber        NVARCHAR(15) = NULL,
    @Address            NVARCHAR(255) = NULL,
    @Occupation         NVARCHAR(100) = NULL,
    @AnnualIncome       DECIMAL(12,2) = NULL,
    @PasswordHash       NVARCHAR(255) = NULL,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS ParentId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        IF NULLIF(LTRIM(RTRIM(ISNULL(@FirstName, N''))), N'') IS NULL
         OR NULLIF(LTRIM(RTRIM(ISNULL(@LastName,  N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: First name and last name are required' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS ParentId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        /* Email is unique per school, not globally, so this is the check that
           matches UQ_Users_School_Email -- and it names the problem instead of
           letting the index raise it. */
        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: Email already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS ParentId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        BEGIN TRANSACTION;

        /* Claimed inside the transaction so an abandoned registration does not
           burn a number. 'Parent' has no seeded SchoolSequences row --
           sp_NextSequence MERGEs one into existence on first use. */
        DECLARE @Seq INT;
        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = N'Parent', @NextValue = @Seq OUTPUT;

        DECLARE @Username NVARCHAR(80) = dbo.fn_GenerateParentUsername(@Code, @FirstName, @LastName, @Seq);

        /* Two parents sharing an initial and surname differ in the sequence
           suffix, so this only trips on a genuine duplicate. */
        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Generated username already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS ParentId,
                   CAST(NULL AS NVARCHAR(80)) AS Username;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        DECLARE @Hash NVARCHAR(255) = ISNULL(@PasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        /* Persons + Users + Addresses in one call; RoleId 5 is Parent. Already
           inside this procedure's transaction, so a later failure unwinds it. */
        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @Hash,
            @RoleId                = 5,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = 1,
            @ActorUserId           = @PerformedByUserId,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        INSERT INTO dbo.Parents (SchoolId, UserId, Occupation, AnnualIncome)
        VALUES (@SchoolId, @UserId, @Occupation, @AnnualIncome);

        DECLARE @ParentId INT = CAST(SCOPE_IDENTITY() AS INT);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Parent.Register', @EntityType = 'Parent', @EntityId = @ParentId,
            @Details = @Username;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @UserId AS UserId,
               @ParentId AS ParentId,
               @Username AS Username;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS ParentId,
               CAST(NULL AS NVARCHAR(80)) AS Username;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
