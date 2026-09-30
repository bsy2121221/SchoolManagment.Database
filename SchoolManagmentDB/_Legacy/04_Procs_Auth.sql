/*==============================================================================
  04_Procs_Auth.sql  --  Authentication, refresh tokens, passwords.

  sp_Login DELIBERATELY KEEPS ITS (@Username, @Password) SIGNATURE.
  The school code is baked into every generated username
  (DPSNOIDA_S_2025_10A_001), so usernames stay globally unique and the React
  login page needs no "select your school" field. sp_Login resolves the tenant
  and returns SchoolId / SchoolCode / SchoolName for the JWT claims.

  @Password is still accepted and still ignored: the API verifies the BCrypt
  hash in C# (AuthService.LoginAsync). Never move hashing into SQL.

  In the old scripts sp_Login was defined twice -- once in StoredProcedures.sql
  and again in StudentRegistrationUpdates.sql -- so whichever file ran last
  silently won. There is exactly one definition now.

  UTC NOTE: the API computes refresh-token expiry with DateTime.UtcNow
  (AuthController.cs:45), so every comparison against ExpiryDate here uses
  GETUTCDATE(). The old procedures used GETDATE(), which expired tokens early
  by the server's UTC offset (5h30m on IST).

  IDENTITY SPLIT: names, phone and address now live in dbo.Persons and
  dbo.Addresses, and the role is dbo.Roles.Id. Every read here goes through
  dbo.vw_Users, which re-flattens them, so the returned column names are the same
  as before with three changes:
      + RoleId          is now the INT role key (was the admission/employee id)
      + RoleIdentifier  is the admission/employee id (renamed from RoleId)
      + PasswordHash    is now returned by sp_Login, which C# needs to verify it
  sp_Login and sp_LoginWithRefreshToken each return a SECOND result set holding
  the caller's permission grid for the JWT.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  sp_Login

  Returns:
      Id, Username, Email, PasswordHash, FirstName, LastName, PhoneNumber,
      Address, RoleId, Role, RoleCode, IsActive, RequirePasswordChange,
      RoleIdentifier, SchoolId, SchoolCode, SchoolName

  PasswordHash IS RETURNED ON PURPOSE. BCrypt.Verify runs in C#
  (AuthService.LoginAsync), so the hash has to travel back with the row. It is
  never put into a DTO or a claim -- AuthRepository reads it, verifies, drops it.

  RoleId is now the INT foreign key to dbo.Roles. The human-facing identifier
  (admission number / employee id) that this column used to carry is returned as
  RoleIdentifier -- a rename, and the one breaking change in this refactor.

  Reads dbo.vw_Users, which re-joins Users + Persons + Roles + primary Address,
  so the flat column list survived the table split.

  Returns NO ROWS when the user is inactive or their school is suspended, so
  the API's existing "user == null -> invalid credentials" path covers both.
  If you want to tell a suspended school apart from a wrong password, look the
  school up separately -- do not relax this filter.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_Login
    @Username NVARCHAR(80),
    @Password NVARCHAR(255) = NULL   -- accepted for compatibility; verified in C#
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.Username,
           u.Email,
           u.PasswordHash,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           /* The human-facing identifier for the role: a student's admission
              number or a teacher's employee id. */
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS st
           ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te
           ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools AS sc
           ON sc.Id = u.SchoolId
    WHERE u.Username = @Username
      AND u.IsActive = 1
      /* SuperAdmin (RoleId 1) has no school; everyone else needs an active one. */
      AND (u.RoleId = 1 OR sc.IsActive = 1);

    /* Second result set: the permission grid for the JWT. Sent with the login row
       so minting a token is one round trip. AuthRepository reads both.

       The eligibility filter is repeated verbatim from the SELECT above. A refused
       login must return NEITHER set: handing back a permission grid for a
       suspended school would tell the caller the account exists, and would leave
       AuthRepository holding claims for a user it is about to reject. */
    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.Users AS us
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = us.RoleId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = us.SchoolId
    WHERE us.Username = @Username
      AND us.IsActive = 1
      AND (us.RoleId = 1 OR sc.IsActive = 1)
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

/*==============================================================================
  sp_RecordLogin -- stamp LastLoginAt and write an audit row.

  Separate from sp_Login because the API calls sp_Login BEFORE verifying the
  password hash; stamping there would record every failed attempt as a login.
  Call this from AuthController after BCrypt.Verify succeeds.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RecordLogin
    @UserId     INT,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolId INT = (SELECT SchoolId FROM dbo.Users WHERE Id = @UserId);

    UPDATE dbo.Users
       SET LastLoginAt = GETDATE()
     WHERE Id = @UserId;

    EXEC dbo.sp_LogAudit
        @SchoolId = @SchoolId, @UserId = @UserId,
        @Action = 'Auth.Login', @EntityType = 'User', @EntityId = @UserId,
        @IpAddress = @IpAddress;
END
GO

/*==============================================================================
  sp_GetUserById

  Also returns PasswordHash: AuthService.ChangePasswordAsync has to verify the
  current password in C# before it can store a new one.

  @SchoolId is optional and confines the lookup to one school. UserRepository
  already passed it -- and this procedure only declared @UserId, so every call
  from GET /api/users/{id} failed outright with "too many arguments specified".
  It is a real filter rather than an ignored parameter because CanAccessUser
  checks that the caller is an admin, not which school they administer: without
  this, one school's admin could read another school's user by guessing an id.
  AuthService reads a user by id alone (it has only the token), so NULL means
  no school filter.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserById
    @UserId   INT,
    @SchoolId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
           u.PasswordHash,
           u.FirstName,
           u.LastName,
           u.FullName,
           u.PhoneNumber,
           u.AlternatePhoneNumber,
           u.Address,
           u.AddressId,
           u.AddressType,
           u.AddressLine1,
           u.AddressLine2,
           u.Landmark,
           u.City,
           u.State,
           u.Country,
           u.PostalCode,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS st ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools  AS sc ON sc.Id = u.SchoolId
    WHERE u.Id = @UserId
      AND (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
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

/*==============================================================================
  sp_ChangePassword -- store an already-hashed password.

  @NewPasswordHash must be a BCrypt hash from the API. The old-password check
  also happens in C#, because only C# can verify a BCrypt hash.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ChangePassword
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255),
    @IpAddress          NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId)
        BEGIN
            SELECT 'Error: User not found.' AS Result;
            RETURN;
        END

        DECLARE @SchoolId INT = (SELECT SchoolId FROM dbo.Users WHERE Id = @UserId);

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash = @NewPasswordHash,
               RequirePasswordChange = 0,
               /* Self-service: the user is their own modifier. */
               ModifiedBy = @UserId,
               UpdatedAt = GETDATE()
         WHERE Id = @UserId;

        /* Changing a password invalidates existing sessions. */
        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Auth.PasswordChanged', @EntityType = 'User', @EntityId = @UserId,
            @IpAddress = @IpAddress;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_ForcePasswordChange -- admin resets a user in their own school.

  @SchoolId is checked against the target user, so a School A admin cannot
  reset a School B user even with a guessed user id.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ForcePasswordChange
    @SchoolId           INT,
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255) = NULL,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND SchoolId = @SchoolId)
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        SET @NewPasswordHash = ISNULL(@NewPasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash = @NewPasswordHash,
               RequirePasswordChange = 1,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId
           AND SchoolId = @SchoolId;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Auth.PasswordReset', @EntityType = 'User', @EntityId = @UserId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_CreateRefreshToken -- issue a token, revoking the user's previous ones.

  @ExpiryDate is UTC (the API passes DateTime.UtcNow.AddDays(n)).

  Returns: Result, TokenId. TokenId is new -- AuthRepository already read the
  first column of this result set as an INT to populate RefreshToken.Id, which
  threw on the string 'Success' every time a token was issued.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateRefreshToken
    @UserId     INT,
    @Token      NVARCHAR(255),
    @ExpiryDate DATETIME,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND IsActive = 1)
        BEGIN
            SELECT 'Error: User not found or inactive.' AS Result, CAST(NULL AS INT) AS TokenId;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        INSERT INTO dbo.RefreshTokens (UserId, Token, ExpiryDate, IsActive)
        VALUES (@UserId, @Token, @ExpiryDate, 1);

        DECLARE @TokenId INT = CAST(SCOPE_IDENTITY() AS INT);

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @TokenId AS TokenId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS TokenId;
    END CATCH
END
GO

/*==============================================================================
  sp_GetRefreshToken -- token plus enough user detail to mint a new JWT.

  SchoolId / SchoolCode / SchoolName are essential here, not decorative: the
  refresh path issues a fresh access token, and if it omitted the school claims
  the refreshed token would have no tenant and every subsequent request would
  fail closed.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRefreshToken
    @Token NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT rt.Id,
           rt.UserId,
           rt.Token,
           rt.ExpiryDate,
           rt.IsActive,
           rt.CreatedAt,
           rt.RevokedAt,
           rt.RevokedByIp,
           rt.ReplacedByToken,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           /* Aliased: rt.IsActive is already in this result set, and two columns
              of the same name make Dapper's mapping order-dependent. */
           u.IsActive AS UserIsActive,
           u.RequirePasswordChange,
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.vw_Users AS u ON u.Id = rt.UserId
    LEFT JOIN dbo.Students AS st ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools  AS sc ON sc.Id = u.SchoolId
    WHERE rt.Token = @Token;
END
GO

/*==============================================================================
  sp_ValidateRefreshToken -- Returns: IsValid, UserId

  A token is valid only if it is active, unrevoked, unexpired (UTC), owned by an
  active user, AND that user's school is still active. The school check is what
  logs out a suspended school on its next refresh.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ValidateRefreshToken
    @Token NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(CASE
               WHEN rt.Id IS NOT NULL
                AND rt.IsActive = 1
                AND rt.RevokedAt IS NULL
                AND rt.ExpiryDate > GETUTCDATE()
                AND u.IsActive = 1
                AND (u.RoleId = 1 OR sc.IsActive = 1)
               THEN 1 ELSE 0
           END AS BIT) AS IsValid,
           rt.UserId
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = u.SchoolId
    WHERE rt.Token = @Token;
END
GO

/*==============================================================================
  sp_RevokeRefreshToken
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RevokeRefreshToken
    @Token              NVARCHAR(255),
    @IpAddress          NVARCHAR(50) = NULL,
    @ReplacedByToken    NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.RefreshTokens WHERE Token = @Token)
        BEGIN
            SELECT 'Error: Refresh token not found.' AS Result;
            RETURN;
        END

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress,
               ReplacedByToken = @ReplacedByToken
         WHERE Token = @Token
           AND IsActive = 1;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_RevokeAllUserRefreshTokens -- Returns: Result, TokensRevoked
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RevokeAllUserRefreshTokens
    @UserId     INT,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        DECLARE @Revoked INT = @@ROWCOUNT;

        SELECT 'Success' AS Result, @Revoked AS TokensRevoked;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS TokensRevoked;
    END CATCH
END
GO

/*==============================================================================
  sp_CleanupExpiredRefreshTokens -- housekeeping.
  Returns: Result, TokensDeleted
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CleanupExpiredRefreshTokens
    @RetainRevokedDays INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DELETE FROM dbo.RefreshTokens
         WHERE ExpiryDate < DATEADD(DAY, -ABS(ISNULL(@RetainRevokedDays, 30)), GETUTCDATE());

        DECLARE @Deleted INT = @@ROWCOUNT;

        SELECT 'Success' AS Result, @Deleted AS TokensDeleted;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS TokensDeleted;
    END CATCH
END
GO

/*==============================================================================
  sp_GetUserRefreshTokens -- session list for a user (admin/debug view).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserRefreshTokens
    @UserId         INT,
    @IncludeRevoked BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT rt.Id,
           rt.UserId,
           rt.Token,
           rt.ExpiryDate,
           rt.IsActive,
           rt.CreatedAt,
           rt.RevokedAt,
           rt.RevokedByIp,
           rt.ReplacedByToken,
           CAST(CASE WHEN rt.ExpiryDate <= GETUTCDATE() THEN 1 ELSE 0 END AS BIT) AS IsExpired
    FROM dbo.RefreshTokens AS rt
    WHERE rt.UserId = @UserId
      AND (@IncludeRevoked = 1 OR rt.IsActive = 1)
    ORDER BY rt.CreatedAt DESC;
END
GO

/*==============================================================================
  sp_GetRefreshTokenStats
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetRefreshTokenStats
    @SchoolId INT = NULL   -- NULL = whole platform (SuperAdmin only)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS TotalTokens,
           SUM(CASE WHEN rt.IsActive = 1 AND rt.ExpiryDate > GETUTCDATE() THEN 1 ELSE 0 END) AS ActiveTokens,
           SUM(CASE WHEN rt.ExpiryDate <= GETUTCDATE() THEN 1 ELSE 0 END) AS ExpiredTokens,
           SUM(CASE WHEN rt.RevokedAt IS NOT NULL THEN 1 ELSE 0 END) AS RevokedTokens,
           COUNT(DISTINCT rt.UserId) AS DistinctUsers
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
    WHERE (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
END
GO

/*==============================================================================
  sp_LoginWithRefreshToken -- one round trip: validate a token and return the
  user detail needed to mint a new JWT.

  Returns no rows if the token is unusable, so the API treats it exactly like a
  failed login.

  Two result sets, matching sp_Login: the user row, then the permission grid. The
  refreshed access token has to carry the same claims as the original, permissions
  included -- and re-reading them here is what makes a permission change take
  effect at the next refresh rather than at the next full login.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LoginWithRefreshToken
    @Token NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.RequirePasswordChange,
           CASE u.RoleId
               WHEN 4 THEN st.StudentId
               WHEN 3 THEN te.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           sc.SchoolCode,
           sc.SchoolName
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.vw_Users AS u ON u.Id = rt.UserId
    LEFT JOIN dbo.Students AS st ON st.SchoolId = u.SchoolId AND st.UserId = u.Id
    LEFT JOIN dbo.Teachers AS te ON te.SchoolId = u.SchoolId AND te.UserId = u.Id
    LEFT JOIN dbo.Schools  AS sc ON sc.Id = u.SchoolId
    WHERE rt.Token = @Token
      AND rt.IsActive = 1
      AND rt.RevokedAt IS NULL
      AND rt.ExpiryDate > GETUTCDATE()
      AND u.IsActive = 1
      AND (u.RoleId = 1 OR sc.IsActive = 1);

    /* Same eligibility filter as above, for the same reason: an unusable token
       must yield no permission grid either. */
    SELECT p.ModuleName,
           p.CanView,
           p.CanCreate,
           p.CanEdit,
           p.CanDelete
    FROM dbo.RefreshTokens AS rt
    INNER JOIN dbo.Users AS us ON us.Id = rt.UserId
    INNER JOIN dbo.RolePermissions AS p ON p.RoleId = us.RoleId
    LEFT JOIN dbo.Schools AS sc ON sc.Id = us.SchoolId
    WHERE rt.Token = @Token
      AND rt.IsActive = 1
      AND rt.RevokedAt IS NULL
      AND rt.ExpiryDate > GETUTCDATE()
      AND us.IsActive = 1
      AND (us.RoleId = 1 OR sc.IsActive = 1)
      AND p.IsActive = 1
    ORDER BY p.ModuleName;
END
GO

/*==============================================================================
  sp_ResetPassword -- admin resets another user's password.

  Called by AuthRepository.ResetPasswordAsync, which had no matching procedure.
  @SchoolId NULL means "the caller is a SuperAdmin, skip the tenant check";
  anything else confines the reset to that school.

  Delegates the work to sp_ForcePasswordChange for a user inside a school so the
  revoke-sessions and audit behaviour stays in one place.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ResetPassword
    @UserId             INT,
    @NewPasswordHash    NVARCHAR(255),
    @SchoolId           INT = NULL,
    @PerformedByUserId  INT = NULL,
    @RequirePasswordChange BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @TargetSchoolId INT;
        SELECT @TargetSchoolId = SchoolId FROM dbo.Users WHERE Id = @UserId;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId)
        BEGIN
            SELECT 'Error: User not found.' AS Result;
            RETURN;
        END

        /* A school admin may only reset within their own school. NULL @SchoolId
           is the SuperAdmin path and is not restricted. */
        IF @SchoolId IS NOT NULL AND ISNULL(@TargetSchoolId, -1) <> @SchoolId
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET PasswordHash          = @NewPasswordHash,
               RequirePasswordChange = @RequirePasswordChange,
               ModifiedBy            = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt             = GETDATE()
         WHERE Id = @UserId;

        /* A reset ends every existing session for that user. */
        UPDATE dbo.RefreshTokens
           SET IsActive  = 0,
               RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId
           AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @TargetSchoolId, @UserId = @PerformedByUserId,
            @Action = 'Auth.PasswordReset', @EntityType = 'User', @EntityId = @UserId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

PRINT '=== 04_Procs_Auth.sql complete ===';
GO

SET NOEXEC OFF;
GO
