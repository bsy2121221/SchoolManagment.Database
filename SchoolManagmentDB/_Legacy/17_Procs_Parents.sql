/*==============================================================================
  17_Procs_Parents.sql  --  Parent registration, profile, children, and the
                            student<->parent link.

  WHY THIS FILE EXISTS AT ALL
    Every other module in this database got a procedure file. Parents did not:
    before this pass the only parent-related procedures anywhere were
    sp_LinkStudentParent and sp_GetStudentChildren, both in 06_Procs_Students.sql.
    ParentRepository.cs therefore carried its own inline SQL for eight of its nine
    methods -- and that SQL was written against the pre-split schema, so most of it
    could not execute at all:

      * RegisterParentAsync inserted into
            Users (SchoolId, Username, Email, PasswordHash, FirstName, LastName,
                   PhoneNumber, Address, Role, RequirePasswordChange)
        Five of those columns do not exist. Names and the phone number live on
        dbo.Persons, the address lives on dbo.Addresses, and the role is
        Users.RoleId. It also omitted PersonId and RoleId, both NOT NULL. Parent
        registration was not "buggy", it was impossible -- the first INSERT threw.
      * GetParentProfileAsync, GetParentsByStudentAsync, GetChildrenByParentAsync
        and UpdateParentAsync read or wrote the same non-existent columns.
      * The username came from  $"{emailPrefix}_{random.Next(1000,9999)}"  inside a
        read-then-write loop -- racy, non-terminating in the worst case, and it put
        a mailbox name into a credential. It is fn_GenerateParentUsername off the
        per-school 'Parent' counter now.
      * There was no transaction, so a Parents insert that failed after the Users
        insert left an orphaned login behind.
      * GetAllParentsAsync / GetParentByIdAsync did use Persons, but INNER JOINed
        dbo.Addresses, so a parent with no address on file vanished from the list
        entirely. Reads here go through dbo.vw_Users, whose OUTER APPLY keeps them.

  CONVENTIONS (the same three as every other proc file)
    @SchoolId is the first parameter; every table is filtered on it; every INSERT
    writes it. Writes return a single Result column reading 'Success' or
    'Error: <reason>', which ProcResult.From() in C# unwraps.

  DEPENDS ON 02_Functions.sql for fn_GenerateParentUsername, sp_NextSequence,
  sp_CreateUserAccount, sp_UpdateUserIdentity, sp_AssertSchool and sp_LogAudit, so
  run 02 before this file. It is numbered 17 because 15 and 16 were already taken
  by the seed and verify scripts; see the run order table in README.md, which
  places it with the other proc files.
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

/*==============================================================================
  sp_GetAllParents -- the school's parents, with their children summarised.

  @IncludeInactive = 1 returns deactivated parents too. sp_GetTeachersWithDetails
  hard-filters IsActive = 1, which is why a soft-deleted teacher is unreachable
  through the API; this takes the flag so the same hole is not dug twice.

  Returns one row per parent. ChildrenNames is comma-joined for display only --
  callers that need the children as rows use sp_GetChildrenByParent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllParents
    @SchoolId        INT,
    @IncludeInactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.SchoolId,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           /* Relationship is per link, so it is meaningless on a whole-school
              list. sp_GetParentsByStudent is the call that fills it. */
           CAST(NULL AS NVARCHAR(20)) AS Relationship,
           kids.ChildrenNames,
           ISNULL(kids.ChildrenCount, 0) AS ChildrenCount
    FROM dbo.Parents AS p
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
    OUTER APPLY (
        SELECT STRING_AGG(cu.FirstName + N' ' + cu.LastName, N', ') AS ChildrenNames,
               COUNT(*) AS ChildrenCount
        FROM dbo.StudentParents AS sp
        INNER JOIN dbo.Students  AS s  ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
        INNER JOIN dbo.vw_Users  AS cu ON cu.SchoolId = s.SchoolId AND cu.Id = s.UserId
        WHERE sp.SchoolId = p.SchoolId
          AND sp.ParentId = p.Id
          AND sp.IsActive = 1
          AND s.IsActive = 1
    ) AS kids
    WHERE p.SchoolId = @SchoolId
      AND (@IncludeInactive = 1 OR p.IsActive = 1)
    ORDER BY u.FirstName, u.LastName;
END
GO

/*==============================================================================
  sp_GetParentById -- one parent, same shape as the list row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentById
    @SchoolId   INT,
    @ParentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.SchoolId,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           CAST(NULL AS NVARCHAR(20)) AS Relationship,
           kids.ChildrenNames,
           ISNULL(kids.ChildrenCount, 0) AS ChildrenCount
    FROM dbo.Parents AS p
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
    OUTER APPLY (
        SELECT STRING_AGG(cu.FirstName + N' ' + cu.LastName, N', ') AS ChildrenNames,
               COUNT(*) AS ChildrenCount
        FROM dbo.StudentParents AS sp
        INNER JOIN dbo.Students  AS s  ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
        INNER JOIN dbo.vw_Users  AS cu ON cu.SchoolId = s.SchoolId AND cu.Id = s.UserId
        WHERE sp.SchoolId = p.SchoolId
          AND sp.ParentId = p.Id
          AND sp.IsActive = 1
          AND s.IsActive = 1
    ) AS kids
    WHERE p.SchoolId = @SchoolId
      AND p.Id = @ParentId;

    /* No IsActive filter on purpose: a deactivated parent must still be readable,
       or the admin who deactivated them cannot see what they did. */
END
GO

/*==============================================================================
  sp_GetParentProfile -- the parent's own screen, keyed on dbo.Users.Id.

  TWO result sets, because ParentProfileDTO carries a Children list:
    1. the parent, their login, and their school
    2. one row per linked child (the sp_GetChildrenByParent shape)

  Keyed on @UserId rather than @ParentId because GET /api/Parents/my-profile has
  only the token's UserId to work with.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentProfile
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           p.SchoolId,
           sch.SchoolCode,
           sch.SchoolName
    FROM dbo.Parents AS p
    INNER JOIN dbo.vw_Users AS u   ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
    INNER JOIN dbo.Schools  AS sch ON sch.Id = p.SchoolId
    WHERE p.SchoolId = @SchoolId
      AND p.UserId = @UserId;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           cu.FirstName,
           cu.LastName,
           cu.Email,
           /* ParentChildDTO declares these three non-nullable, and a student
              between classes has none, so the empty string is the honest answer
              rather than a null landing in a string property. */
           ISNULL(c.ClassName, N'') AS ClassName,
           ISNULL(c.Grade,     N'') AS Grade,
           ISNULL(c.Section,   N'') AS Section,
           sp.Relationship
    FROM dbo.Parents AS p
    INNER JOIN dbo.StudentParents AS sp ON sp.SchoolId = p.SchoolId AND sp.ParentId = p.Id
    INNER JOIN dbo.Students       AS s  ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users       AS cu ON cu.SchoolId = s.SchoolId AND cu.Id = s.UserId
    LEFT  JOIN dbo.Classes        AS c  ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE p.SchoolId = @SchoolId
      AND p.UserId = @UserId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY cu.FirstName, cu.LastName;
END
GO

/*==============================================================================
  sp_UpdateParent -- admin edit of one parent.

  Returns: Result

  Every field named is written, so this is a replacement rather than a patch: a
  NULL phone number or address clears what is on file. That needs saying because
  sp_UpsertPerson treats a NULL @PhoneNumber as "leave it alone" (it is shared
  with the partial-update callers), which is why the phone is set explicitly
  below rather than left to the helper.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateParent
    @SchoolId       INT,
    @ParentId       INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Occupation     NVARCHAR(100) = NULL,
    @AnnualIncome   DECIMAL(12,2) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Parents
                                WHERE SchoolId = @SchoolId AND Id = @ParentId);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Names, email and address, fanned out over Persons / Users / Addresses.
           Passing @Address through means a blank one deactivates the address row,
           which is sp_UpsertAddress's documented behaviour. */
        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @ModifiedBy;

        /* The one field the helper cannot clear. Without this an admin removing a
           parent's phone number would see it reappear on the next read. */
        UPDATE per
           SET per.PhoneNumber = @PhoneNumber,
               per.UpdatedAt   = GETDATE()
        FROM dbo.Persons AS per
        INNER JOIN dbo.Users AS usr ON usr.PersonId = per.Id
        WHERE usr.Id = @UserId
          AND usr.SchoolId = @SchoolId;

        UPDATE dbo.Parents
           SET Occupation   = @Occupation,
               AnnualIncome = @AnnualIncome,
               UpdatedAt    = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ParentId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @ModifiedBy,
            @Action = 'Parent.Update', @EntityType = 'Parent', @EntityId = @ParentId;

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
  sp_DeleteParent -- soft delete, refusing to orphan history.

  Returns: Result

  A parent who has recorded a fee payment is kept, exactly as a student with
  attendance is: FeePayments.PaidBy is a FK to Users, and the receipt has to keep
  naming somebody. Their children links are deactivated along with the account,
  following sp_DeleteStudent -- the alternative, refusing while any child is
  linked, would force an admin to unlink three children by hand before they could
  deactivate one duplicate record.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteParent
    @SchoolId           INT,
    @ParentId           INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Parents
                                WHERE SchoolId = @SchoolId AND Id = @ParentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.FeePayments
                    WHERE SchoolId = @SchoolId AND PaidBy = @UserId)
        BEGIN
            SELECT 'Error: Cannot delete a parent who has recorded fee payments. Deactivate the account instead.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.StudentParents SET IsActive = 0
         WHERE SchoolId = @SchoolId AND ParentId = @ParentId;

        UPDATE dbo.Parents SET IsActive = 0, UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ParentId;

        UPDATE dbo.Users
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @UserId;

        UPDATE dbo.Persons
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = (SELECT PersonId FROM dbo.Users WHERE Id = @UserId);

        UPDATE dbo.RefreshTokens SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Parent.Delete', @EntityType = 'Parent', @EntityId = @ParentId;

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
  sp_UnlinkStudentParent -- detach a parent from a student.

  Returns: Result

  The mirror of sp_LinkStudentParent, and it follows sp_RemoveStudentSubject on
  the awkward case: no link row at all is an error naming that, while a row that
  is already inactive reports Success, because the caller asked for a state the
  database is already in. The old repository returned `rows > 0` from a bare
  UPDATE, so unlinking twice reported "Failed to unlink parent from student" and
  told the admin nothing about which of the two reasons applied.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UnlinkStudentParent
    @SchoolId           INT,
    @StudentId          INT,
    @ParentId           INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Parents WHERE SchoolId = @SchoolId AND Id = @ParentId)
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.StudentParents
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND ParentId = @ParentId)
        BEGIN
            SELECT 'Error: That parent is not linked to this student' AS Result;
            RETURN;
        END

        UPDATE dbo.StudentParents
           SET IsActive = 0
         WHERE SchoolId = @SchoolId
           AND StudentId = @StudentId
           AND ParentId = @ParentId
           AND IsActive = 1;

        IF @@ROWCOUNT > 0
            EXEC dbo.sp_LogAudit
                @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
                @Action = 'Parent.Unlink', @EntityType = 'StudentParent', @EntityId = @StudentId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_GetParentsByStudent -- who to contact about one student.

  Same row shape as sp_GetAllParents, with Relationship filled in: this is the one
  call where it means something, because it is a property of the link rather than
  of the parent.

  The old query smuggled sp.Relationship out through the ChildrenNames column, so
  a caller reading ParentDTO.ChildrenNames got 'Father' where it expected a list
  of children. Both fields are populated properly here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetParentsByStudent
    @SchoolId   INT,
    @StudentId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.Id,
           p.Occupation,
           p.AnnualIncome,
           p.IsActive,
           p.SchoolId,
           p.CreatedAt,
           p.UpdatedAt,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           sp.Relationship,
           kids.ChildrenNames,
           ISNULL(kids.ChildrenCount, 0) AS ChildrenCount
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Parents  AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = p.SchoolId  AND u.Id = p.UserId
    OUTER APPLY (
        SELECT STRING_AGG(cu.FirstName + N' ' + cu.LastName, N', ') AS ChildrenNames,
               COUNT(*) AS ChildrenCount
        FROM dbo.StudentParents AS sp2
        INNER JOIN dbo.Students AS s2  ON s2.SchoolId = sp2.SchoolId AND s2.Id = sp2.StudentId
        INNER JOIN dbo.vw_Users AS cu  ON cu.SchoolId = s2.SchoolId  AND cu.Id = s2.UserId
        WHERE sp2.SchoolId = p.SchoolId
          AND sp2.ParentId = p.Id
          AND sp2.IsActive = 1
          AND s2.IsActive = 1
    ) AS kids
    WHERE sp.SchoolId = @SchoolId
      AND sp.StudentId = @StudentId
      AND sp.IsActive = 1
      AND p.IsActive = 1
    ORDER BY sp.Relationship, u.FirstName, u.LastName;
END
GO

/*==============================================================================
  sp_GetChildrenByParent -- the children of one parent, keyed on Parents.Id.

  sp_GetStudentChildren in 06_Procs_Students.sql answers the same question from
  the parent's Users.Id, which is what the parent portal has. This one takes
  Parents.Id, which is what an administrator looking at a parent record has, and
  is why both exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetChildrenByParent
    @SchoolId   INT,
    @ParentId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           u.FirstName,
           u.LastName,
           u.Email,
           ISNULL(c.ClassName, N'') AS ClassName,
           ISNULL(c.Grade,     N'') AS Grade,
           ISNULL(c.Section,   N'') AS Section,
           sp.Relationship
    FROM dbo.StudentParents AS sp
    INNER JOIN dbo.Students AS s ON s.SchoolId = sp.SchoolId AND s.Id = sp.StudentId
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId  AND u.Id = s.UserId
    LEFT  JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId  AND c.Id = s.ClassId
    WHERE sp.SchoolId = @SchoolId
      AND sp.ParentId = @ParentId
      AND sp.IsActive = 1
      AND s.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

PRINT '=== 17_Procs_Parents.sql complete ===';
GO

SET NOEXEC OFF;
GO
