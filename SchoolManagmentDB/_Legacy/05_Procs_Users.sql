/*==============================================================================
  05_Procs_Users.sql  --  User administration within one school.

  Result-set column names are unchanged from the old procedures, so the C# DTOs
  and React tables keep working. What changed is the WHERE clauses: every one is
  now anchored on @SchoolId, and the "does this user exist" guards check
  SchoolId too -- so a School A admin who guesses a School B user id gets
  "User not found in this school" instead of editing another tenant's data.

  IDENTITY SPLIT
    Reads go through dbo.vw_Users (Users + Persons + Roles + primary Address
    re-flattened), which is why FirstName / LastName / PhoneNumber / Address are
    still single columns here after the tables were split.
    Writes go through sp_UpdateUserIdentity (02_Functions.sql), which fans the
    edit back out to the right three tables.
    RoleId now means dbo.Roles.Id. The admission-number / employee-id value this
    column used to carry is returned as RoleIdentifier.
    Every write procedure takes @ModifiedBy and records it on the rows it touches.
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
  sp_GetAllUsers -- the paged, filtered user list.

  TWO RESULT SETS: the page, then the total row count. UserRepository already
  called it with @IsActive / @SearchTerm / @Page / @PageSize and read two sets via
  QueryMultipleAsync, but the procedure only took @SchoolId and @Role and returned
  one -- so paging silently did nothing and the total was always 0. The signature
  matches the caller now.

  @IsActive NULL returns active and inactive users together; the old procedure
  hard-coded IsActive = 1 and gave the admin no way to see a deactivated account.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllUsers
    @SchoolId   INT,
    @Role       NVARCHAR(50) = NULL,
    @RoleId     INT = NULL,
    @IsActive   BIT = NULL,
    @SearchTerm NVARCHAR(100) = NULL,
    @Page       INT = 1,
    @PageSize   INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    SET @Page       = CASE WHEN ISNULL(@Page, 1) < 1 THEN 1 ELSE @Page END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 20) BETWEEN 1 AND 500 THEN @PageSize ELSE 20 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');
    SET @RoleId     = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    DECLARE @Offset INT = (@Page - 1) * @PageSize;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
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
           /* The bytes themselves are never sent with a list -- the client asks
              for them one at a time from GET /users/{id}/profile-picture. This
              flag is what tells it whether that request is worth making. */
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
    WHERE u.SchoolId = @SchoolId
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR u.FirstName LIKE '%' + @SearchTerm + '%'
           OR u.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%')
    ORDER BY u.CreatedAt DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    /* Counted off Users alone: the view's joins cannot change the row count, and
       counting the base table keeps this off the address OUTER APPLY. */
    SELECT COUNT(*) AS TotalCount
    FROM dbo.Users AS u
    INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
    WHERE u.SchoolId = @SchoolId
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR p.FirstName LIKE '%' + @SearchTerm + '%'
           OR p.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%');
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

/*==============================================================================
  sp_ChangeUserRole -- move a user to a different role.

  Kept apart from sp_UpdateUser: a role change is an authorisation event, not a
  profile edit, and it has to invalidate the user's tokens. Their old JWT still
  carries the old role and the old permission grid until it expires, so the
  sessions are revoked and the user re-authenticates.

  SuperAdmin is not reachable from here in either direction -- CK_Users_SchoolScope
  requires SchoolId IS NULL for role 1, and this procedure is school-scoped.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ChangeUserRole
    @SchoolId   INT,
    @UserId     INT,
    @RoleId     INT = NULL,
    @Role       NVARCHAR(50) = NULL,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @CurrentRoleId INT;

        SELECT @CurrentRoleId = RoleId
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId;

        IF @CurrentRoleId IS NULL
        BEGIN
            SELECT 'Error: User not found in this school.' AS Result;
            RETURN;
        END

        DECLARE @NewRoleId INT;
        EXEC dbo.sp_ResolveRole @RoleId = @RoleId, @Role = @Role,
                                @ResolvedRoleId = @NewRoleId OUTPUT;

        IF @NewRoleId = 1
        BEGIN
            SELECT 'Error: SuperAdmin cannot be assigned to a school user.' AS Result;
            RETURN;
        END

        IF @NewRoleId = @CurrentRoleId
        BEGIN
            SELECT 'Success' AS Result;   -- already there; nothing to do
            RETURN;
        END

        /* Students, Teachers and Parents carry role-specific rows keyed on UserId.
           Moving a user out of one of those roles would leave that row behind
           pointing at someone who is no longer, say, a teacher. */
        IF @CurrentRoleId IN (3, 4, 5)
        BEGIN
            SELECT 'Error: Students, teachers and parents cannot be reassigned to another role. '
                 + 'Deactivate this account and create the new one.' AS Result;
            RETURN;
        END

        IF @NewRoleId IN (3, 4, 5)
        BEGIN
            SELECT 'Error: Use the student, teacher or parent registration procedure '
                 + 'to create those accounts.' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET RoleId     = @NewRoleId,
               ModifiedBy = ISNULL(@ModifiedBy, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE Id = @UserId AND SchoolId = @SchoolId;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        DECLARE @Details NVARCHAR(200) =
            dbo.fn_RoleName(@CurrentRoleId) + N' -> ' + dbo.fn_RoleName(@NewRoleId);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @ModifiedBy,
            @Action = 'User.RoleChange', @EntityType = 'User', @EntityId = @UserId,
            @Details = @Details;

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
  sp_DeleteUser -- soft delete, refusing to orphan historical data.

  Same guard rails as before (no deleting admins, no deleting anyone with
  attendance / results / fees), with two corrections:
    * the teacher checks used Classes.ClassTeacherId = @UserId, but that column
      now holds Teachers.Id, so the user id is resolved first;
    * every check is scoped to @SchoolId.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteUser
    @SchoolId           INT,
    @UserId             INT,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        /* RoleId literals: 1 SuperAdmin, 2 Admin, 3 Teacher, 4 Student, 5 Parent,
           fixed by the Roles seed in 01_Schema.sql. @UserRole is kept for the audit
           details. */
        DECLARE @RoleId INT, @UserRole NVARCHAR(50);

        SELECT @RoleId = RoleId, @UserRole = dbo.fn_RoleName(RoleId)
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId AND IsActive = 1;

        IF @RoleId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        IF @RoleId IN (1, 2)
        BEGIN
            SELECT 'Error: Cannot delete admin users' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        IF @RoleId = 3
        BEGIN
            DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                                       WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete teacher who is assigned to active classes' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Attendance
                        WHERE SchoolId = @SchoolId AND MarkedBy = @UserId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete teacher who has historical attendance data' AS Result;
                RETURN;
            END

            UPDATE dbo.Teachers
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

            UPDATE dbo.TeacherSubjects SET IsActive = 0
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

            UPDATE dbo.TeacherSubjectAssignments SET IsActive = 0
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;

            UPDATE dbo.TeacherSchedule SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId;
        END
        ELSE IF @RoleId = 4
        BEGIN
            DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                                       WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.Attendance
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with attendance records. This student has historical data.' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Results
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with exam results. This student has historical data.' AS Result;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM dbo.Fees
                        WHERE SchoolId = @SchoolId AND StudentId = @StudentId)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete student with fee records. This student has historical data.' AS Result;
                RETURN;
            END

            UPDATE dbo.Students
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

            UPDATE dbo.StudentSubjects SET IsActive = 0
             WHERE SchoolId = @SchoolId AND StudentId = @StudentId;
        END
        ELSE IF @RoleId = 5
        BEGIN
            DECLARE @ParentId INT = (SELECT Id FROM dbo.Parents
                                      WHERE SchoolId = @SchoolId AND UserId = @UserId);

            IF EXISTS (SELECT 1 FROM dbo.StudentParents
                        WHERE SchoolId = @SchoolId AND ParentId = @ParentId AND IsActive = 1)
            BEGIN
                ROLLBACK TRANSACTION;
                SELECT 'Error: Cannot delete parent with active children relationships' AS Result;
                RETURN;
            END

            UPDATE dbo.Parents
               SET IsActive = 0, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        END

        UPDATE dbo.Users
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId AND SchoolId = @SchoolId;

        /* The person row follows the account: Users.PersonId is unique, so this
           person exists only to be this user. The row is kept, not deleted --
           attendance and results still reference the user id behind it. */
        UPDATE dbo.Persons
           SET IsActive = 0,
               ModifiedBy = ISNULL(@PerformedByUserId, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = (SELECT PersonId FROM dbo.Users WHERE Id = @UserId);

        /* A deactivated user must not keep a working session. */
        UPDATE dbo.RefreshTokens
           SET IsActive = 0, RevokedAt = GETUTCDATE()
         WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'User.Delete', @EntityType = 'User', @EntityId = @UserId,
            @Details = @UserRole;

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
  sp_GetUserDetails -- one row, with the role-specific columns filled in.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserDetails
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
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
           u.LastLoginAt,
           u.CreatedBy,
           u.CreatedByUsername,
           u.ModifiedBy,
           u.ModifiedByUsername,
           u.CreatedAt,
           u.UpdatedAt,
           u.RequirePasswordChange,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,

           -- Student
           CASE WHEN u.RoleId = 4 THEN s.RollNumber    END AS RollNumber,
           CASE WHEN u.RoleId = 4 THEN s.DateOfBirth   END AS DateOfBirth,
           CASE WHEN u.RoleId = 4 THEN s.FatherName    END AS FatherName,
           CASE WHEN u.RoleId = 4 THEN s.MotherName    END AS MotherName,
           CASE WHEN u.RoleId = 4 THEN s.BloodGroup    END AS BloodGroup,
           CASE WHEN u.RoleId = 4 THEN s.AdmissionDate END AS AdmissionDate,
           CASE WHEN u.RoleId = 4 THEN c.ClassName     END AS ClassName,
           CASE WHEN u.RoleId = 4 THEN c.Grade         END AS Grade,
           CASE WHEN u.RoleId = 4 THEN c.Section       END AS Section,

           -- Teacher
           CASE WHEN u.RoleId = 3 THEN t.Subject       END AS Subject,
           CASE WHEN u.RoleId = 3 THEN t.Qualification END AS Qualification,
           CASE WHEN u.RoleId = 3 THEN t.Experience    END AS Experience,
           CASE WHEN u.RoleId = 3 THEN t.Salary        END AS Salary,
           CASE WHEN u.RoleId = 3 THEN t.JoinDate      END AS JoinDate,

           -- Parent
           CASE WHEN u.RoleId = 5 THEN p.Occupation    END AS Occupation,
           CASE WHEN u.RoleId = 5 THEN p.AnnualIncome  END AS AnnualIncome,

           u.SchoolId
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id AND u.RoleId = 4
    LEFT JOIN dbo.Classes  AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id AND u.RoleId = 3
    LEFT JOIN dbo.Parents  AS p ON p.SchoolId = u.SchoolId AND p.UserId = u.Id AND u.RoleId = 5
    WHERE u.Id = @UserId
      AND u.SchoolId = @SchoolId
      AND u.IsActive = 1;

    /* Second set: the caller's own permission grid, so the profile screen can
       render what this user is allowed to do without a second request. */
    EXEC dbo.sp_GetUserPermissions @UserId = @UserId;
END
GO

/*==============================================================================
  sp_GetUserStats -- role-dependent counters for the profile page.

  Two fixes carried over from the old version:
    * teacher stats keyed off Classes.ClassTeacherId = @UserId, but that column
      holds Teachers.Id; the user id is resolved first now.
    * the overdue-fee count used
          f.Id NOT IN (SELECT FeeId FROM FeePayments GROUP BY FeeId
                       HAVING SUM(AmountPaid) >= (SELECT Amount FROM Fees WHERE Id = FeeId))
      The inner correlation on FeeId inside a HAVING is fragile and cannot use
      an index. It is a LEFT JOIN over aggregated payments now.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleId INT;

    SELECT @RoleId = RoleId
    FROM dbo.Users
    WHERE Id = @UserId AND SchoolId = @SchoolId;

    IF @RoleId = 3   -- Teacher
    BEGIN
        DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                                   WHERE SchoolId = @SchoolId AND UserId = @UserId);

        SELECT (SELECT COUNT(*) FROM dbo.Classes
                 WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1) AS ClassesAssigned,

               (SELECT COUNT(DISTINCT s.Id)
                  FROM dbo.Classes AS c
                  INNER JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id
                 WHERE c.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
                   AND c.IsActive = 1 AND s.IsActive = 1) AS StudentsUnderCare,

               (SELECT COUNT(*) FROM dbo.TeacherSubjects
                 WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1) AS SubjectsAssigned,

               (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND MarkedBy = @UserId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))) AS AttendanceMarkedLastMonth;
    END
    ELSE IF @RoleId = 4   -- Student
    BEGIN
        DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                                   WHERE SchoolId = @SchoolId AND UserId = @UserId);

        SELECT (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))
                   AND IsPresent = 1) AS PresentLastMonth,

               (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))
                   AND IsPresent = 0) AS AbsentLastMonth,

               (SELECT COUNT(*) FROM dbo.Results
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalResults,

               (SELECT COUNT(*) FROM dbo.Fees
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalFees,

               (SELECT COUNT(*)
                  FROM dbo.Fees AS f
                  LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                               FROM dbo.FeePayments
                              WHERE PaymentStatus = 'Completed'
                              GROUP BY SchoolId, FeeId) AS p
                         ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
                 WHERE f.SchoolId = @SchoolId
                   AND f.StudentId = @StudentId
                   AND f.IsActive = 1
                   AND f.DueDate < CAST(GETDATE() AS DATE)
                   AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees;
    END
    ELSE IF @RoleId = 5   -- Parent
    BEGIN
        SELECT (SELECT COUNT(*)
                  FROM dbo.StudentParents AS sp
                  INNER JOIN dbo.Parents AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
                 WHERE p.SchoolId = @SchoolId AND p.UserId = @UserId AND sp.IsActive = 1) AS TotalChildren;
    END
    ELSE
    BEGIN
        SELECT 0 AS NoStats;
    END
END
GO

/*==============================================================================
  sp_SearchUsers
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_SearchUsers
    @SchoolId       INT,
    @SearchTerm     NVARCHAR(100) = NULL,
    @Role           NVARCHAR(50) = NULL,
    @RoleId         INT = NULL,
    @PageSize       INT = 50,
    @PageNumber     INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 50) BETWEEN 1 AND 500 THEN @PageSize ELSE 50 END;
    SET @SearchTerm = NULLIF(LTRIM(RTRIM(ISNULL(@SearchTerm, N''))), N'');
    SET @RoleId     = ISNULL(@RoleId, dbo.fn_RoleId(@Role));

    DECLARE @Offset INT = (@PageNumber - 1) * @PageSize;

    SELECT u.Id,
           u.PersonId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.FullName,
           u.PhoneNumber,
           u.Address,
           u.RoleId,
           u.Role,
           u.RoleCode,
           u.IsActive,
           u.CreatedAt,
           CAST(CASE WHEN u.ProfilePicture IS NULL THEN 0 ELSE 1 END AS BIT) AS HasProfilePicture,
           CASE u.RoleId
               WHEN 4 THEN s.StudentId
               WHEN 3 THEN t.EmployeeId
               ELSE NULL
           END AS RoleIdentifier,
           u.SchoolId,
           COUNT(*) OVER () AS TotalCount
    FROM dbo.vw_Users AS u
    LEFT JOIN dbo.Students AS s ON s.SchoolId = u.SchoolId AND s.UserId = u.Id
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
    WHERE u.SchoolId = @SchoolId
      AND u.IsActive = 1
      AND (@RoleId IS NULL OR u.RoleId = @RoleId)
      AND (@SearchTerm IS NULL
           OR u.FirstName LIKE '%' + @SearchTerm + '%'
           OR u.LastName  LIKE '%' + @SearchTerm + '%'
           OR u.Username  LIKE '%' + @SearchTerm + '%'
           OR u.Email     LIKE '%' + @SearchTerm + '%')
    ORDER BY u.CreatedAt DESC
    OFFSET @Offset ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

/*==============================================================================
  sp_GetUserActivityLog -- Returns: ActivityType, ActivityDate, ActivityDescription

  The old version faked this feed: it UNIONed Users.UpdatedAt three times, so
  "Login Activity" and "Profile Update" always showed the same timestamp and
  nothing was real history. It reads the AuditLog table now.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserActivityLog
    @SchoolId   INT,
    @UserId     INT,
    @TopCount   INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    SET @TopCount = CASE WHEN ISNULL(@TopCount, 10) BETWEEN 1 AND 500 THEN @TopCount ELSE 10 END;

    SELECT TOP (@TopCount)
           al.Action AS ActivityType,
           al.CreatedAt AS ActivityDate,
           CASE
               WHEN al.Details IS NOT NULL THEN al.Action + ': ' + al.Details
               WHEN al.EntityType IS NOT NULL THEN al.Action + ' on ' + al.EntityType
               ELSE al.Action
           END AS ActivityDescription,
           al.EntityType,
           al.EntityId,
           al.IpAddress
    FROM dbo.AuditLog AS al
    WHERE al.SchoolId = @SchoolId
      AND al.UserId = @UserId
    ORDER BY al.CreatedAt DESC;
END
GO

/*==============================================================================
  sp_ToggleUserStatus
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ToggleUserStatus
    @SchoolId   INT,
    @UserId     INT,
    @IsActive   BIT,
    @UpdatedBy  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @RoleId INT, @PersonId INT;

        SELECT @RoleId = RoleId, @PersonId = PersonId
        FROM dbo.Users
        WHERE Id = @UserId AND SchoolId = @SchoolId;

        IF @RoleId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Users
           SET IsActive = @IsActive,
               ModifiedBy = ISNULL(@UpdatedBy, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @UserId
           AND SchoolId = @SchoolId;

        UPDATE dbo.Persons
           SET IsActive = @IsActive,
               ModifiedBy = ISNULL(@UpdatedBy, ModifiedBy),
               UpdatedAt = GETDATE()
         WHERE Id = @PersonId;

        IF @RoleId = 3        -- Teacher
            UPDATE dbo.Teachers SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        ELSE IF @RoleId = 4   -- Student
            UPDATE dbo.Students SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;
        ELSE IF @RoleId = 5   -- Parent
            UPDATE dbo.Parents SET IsActive = @IsActive, UpdatedAt = GETDATE()
             WHERE SchoolId = @SchoolId AND UserId = @UserId;

        IF @IsActive = 0
            UPDATE dbo.RefreshTokens
               SET IsActive = 0, RevokedAt = GETUTCDATE()
             WHERE UserId = @UserId AND IsActive = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedBy,
            @Action = 'User.ToggleStatus', @EntityType = 'User', @EntityId = @UserId;

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
  sp_UpdateUserStatus -- the name UserRepository.UpdateUserStatusAsync calls.

  Another procedure the repository referenced but that was never defined. Passes
  straight through to sp_ToggleUserStatus.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateUserStatus
    @SchoolId   INT,
    @UserId     INT,
    @IsActive   BIT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_ToggleUserStatus
        @SchoolId  = @SchoolId,
        @UserId    = @UserId,
        @IsActive  = @IsActive,
        @UpdatedBy = @ModifiedBy;
END
GO

PRINT '=== 05_Procs_Users.sql complete ===';
GO

SET NOEXEC OFF;
GO
