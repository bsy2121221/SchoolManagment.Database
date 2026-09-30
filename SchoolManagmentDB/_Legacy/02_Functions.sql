/*==============================================================================
  02_Functions.sql  --  Helpers: per-school sequences, identifier formatting,
                        grade calculation, tenant guards.

  WHY sp_NextSequence EXISTS
    The old code numbered students with
        (SELECT COUNT(*) + 1 FROM Students WHERE ClassId = @ClassId)
    which hands the same number to two concurrent registrations and re-uses a
    number after a delete. Counters now live in SchoolSequences and are read
    under a lock.

  WHY THE fn_Generate* FUNCTIONS TAKE @Seq
    A T-SQL function cannot execute a stored procedure, so it cannot draw a
    sequence value. The registration procedures call sp_NextSequence first and
    pass the number in; these functions are pure formatters.

  Run after 01_Schema.sql. All objects are CREATE OR ALTER, so this file is
  safe to re-run on its own.
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
  sp_NextSequence -- atomically claim the next number in a per-school counter.

  @SequenceName: 'Student' | 'Employee' | 'Receipt' | 'Roll:<ClassId>'

  MERGE ... WITH (HOLDLOCK) is the standard safe upsert: HOLDLOCK takes a range
  lock on the key so two sessions cannot both take the NOT MATCHED branch and
  collide on the primary key. Enrolling the same class from two sessions at once
  therefore yields two distinct roll numbers.

  Call inside the caller's transaction so the number is rolled back with the
  rest of the work if registration fails.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_NextSequence
    @SchoolId       INT,
    @SequenceName   NVARCHAR(50),
    @NextValue      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Claimed TABLE (Val INT);

    MERGE dbo.SchoolSequences WITH (HOLDLOCK) AS tgt
    USING (SELECT @SchoolId AS SchoolId, @SequenceName AS SequenceName) AS src
        ON tgt.SchoolId = src.SchoolId
       AND tgt.SequenceName = src.SequenceName
    WHEN MATCHED THEN
        UPDATE SET LastValue = tgt.LastValue + 1,
                   UpdatedAt = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (SchoolId, SequenceName, LastValue)
        VALUES (src.SchoolId, src.SequenceName, 1)
    OUTPUT inserted.LastValue INTO @Claimed;

    SELECT @NextValue = Val FROM @Claimed;
END
GO

/*==============================================================================
  sp_PeekSequence -- current value without consuming it (for preview endpoints).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PeekSequence
    @SchoolId       INT,
    @SequenceName   NVARCHAR(50),
    @NextValue      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @NextValue = ISNULL(LastValue, 0) + 1
    FROM dbo.SchoolSequences
    WHERE SchoolId = @SchoolId
      AND SequenceName = @SequenceName;

    SET @NextValue = ISNULL(@NextValue, 1);
END
GO

/*==============================================================================
  fn_SanitizeCode -- uppercase and strip everything outside A-Z0-9.

  The BIN collation is deliberate: under the database's default case-insensitive
  collation, '[^A-Z0-9]' also matches lowercase letters, so the pattern would
  behave unpredictably.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_SanitizeCode (@Text NVARCHAR(200))
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @Result NVARCHAR(200) = UPPER(ISNULL(@Text, N''));
    DECLARE @Pos INT = PATINDEX(N'%[^A-Z0-9]%', @Result COLLATE Latin1_General_BIN);

    WHILE @Pos > 0
    BEGIN
        SET @Result = STUFF(@Result, @Pos, 1, N'');
        SET @Pos = PATINDEX(N'%[^A-Z0-9]%', @Result COLLATE Latin1_General_BIN);
    END

    RETURN @Result;
END
GO

/*==============================================================================
  fn_GenerateStudentId -- DPSNOIDA_2025_10A_001

  The school code prefix is what keeps admission numbers distinct across
  schools. Without it, two schools both enrolling into "10A" in 2025 produce
  the same value.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateStudentId (
    @SchoolCode NVARCHAR(12),
    @ClassName  NVARCHAR(50),
    @Year       INT,
    @Seq        INT
)
RETURNS NVARCHAR(40)
AS
BEGIN
    DECLARE @Class NVARCHAR(20) = LEFT(dbo.fn_SanitizeCode(@ClassName), 10);
    IF @Class = N'' SET @Class = N'GEN';

    RETURN UPPER(@SchoolCode) + N'_'
         + CAST(@Year AS NVARCHAR(4)) + N'_'
         + @Class + N'_'
         + RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END);
END
GO

/*==============================================================================
  fn_GenerateStudentUsername -- DPSNOIDA202510A001

  Globally unique, so Users.Username stays a single-column UNIQUE and sp_Login
  keeps its (@Username, @Password) signature. That is the whole reason the
  React login page needs no "school" field.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateStudentUsername (
    @SchoolCode NVARCHAR(12),
    @ClassName  NVARCHAR(50),
    @Year       INT,
    @Seq        INT
)
RETURNS NVARCHAR(80)
AS
BEGIN
    DECLARE @Class NVARCHAR(20) = LEFT(dbo.fn_SanitizeCode(@ClassName), 10);
    IF @Class = N'' SET @Class = N'GEN';

    RETURN UPPER(@SchoolCode)
         + CAST(@Year AS NVARCHAR(4))
         + @Class
         + RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END);
END
GO

/*==============================================================================
  fn_GenerateTeacherUsername -- DPSNOIDA_T_RSHARMA01
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateTeacherUsername (
    @SchoolCode NVARCHAR(12),
    @FirstName  NVARCHAR(50),
    @LastName   NVARCHAR(50),
    @Seq        INT
)
RETURNS NVARCHAR(80)
AS
BEGIN
    DECLARE @First NVARCHAR(50) = dbo.fn_SanitizeCode(@FirstName);
    DECLARE @Last  NVARCHAR(50) = dbo.fn_SanitizeCode(@LastName);

    DECLARE @Base NVARCHAR(30) = LEFT(ISNULL(LEFT(@First, 1), N'') + @Last, 20);
    IF @Base = N'' SET @Base = N'STAFF';

    RETURN UPPER(@SchoolCode) + N'_T_' + @Base
         + RIGHT(N'00' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 99 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 2 END);
END
GO

/*==============================================================================
  fn_GenerateTeacherEmployeeId -- DPSNOIDA_EMP_0007
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateTeacherEmployeeId (
    @SchoolCode NVARCHAR(12),
    @Seq        INT
)
RETURNS NVARCHAR(30)
AS
BEGIN
    RETURN UPPER(@SchoolCode) + N'_EMP_'
         + RIGHT(N'0000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 9999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 4 END);
END
GO

/*==============================================================================
  fn_GenerateParentUsername -- DPSNOIDA_P_RSHARMA01

  Same construction as fn_GenerateTeacherUsername, with a _P_ marker and its own
  per-school 'Parent' counter, so a parent and a teacher of the same name cannot
  collide on Users.Username.

  It replaces what ParentRepository.RegisterParentAsync did in C#:

      var username = $"{emailPrefix}_{random.Next(1000, 9999)}";
      while (usernameExists) { re-roll; re-read; }

  which is the read-then-write race this file exists to remove, leaked a mailbox
  name into a credential, and could in principle never terminate. The suffix here
  is a claimed sequence value, so two admins registering at once get two numbers.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateParentUsername (
    @SchoolCode NVARCHAR(12),
    @FirstName  NVARCHAR(50),
    @LastName   NVARCHAR(50),
    @Seq        INT
)
RETURNS NVARCHAR(80)
AS
BEGIN
    DECLARE @First NVARCHAR(50) = dbo.fn_SanitizeCode(@FirstName);
    DECLARE @Last  NVARCHAR(50) = dbo.fn_SanitizeCode(@LastName);

    DECLARE @Base NVARCHAR(30) = LEFT(ISNULL(LEFT(@First, 1), N'') + @Last, 20);
    IF @Base = N'' SET @Base = N'PARENT';

    RETURN UPPER(@SchoolCode) + N'_P_' + @Base
         + RIGHT(N'00' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 99 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 2 END);
END
GO

/*==============================================================================
  fn_GenerateReceiptNumber -- DPSNOIDA_RCPT_2025_000123
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateReceiptNumber (
    @SchoolCode NVARCHAR(12),
    @Year       INT,
    @Seq        INT
)
RETURNS NVARCHAR(40)
AS
BEGIN
    RETURN UPPER(@SchoolCode) + N'_RCPT_'
         + CAST(@Year AS NVARCHAR(4)) + N'_'
         + RIGHT(N'000000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 6 END);
END
GO

/*==============================================================================
  fn_CalculateGrade -- letter grade from marks, using THAT school's scale.

  Thresholds come from the school's own Settings rows (category
  'AcademicSettings'), so two schools on the same instance can grade
  differently. Falls back to the defaults below if a school has no rows yet, so
  it never returns NULL for valid marks.

  Callers pass this only when the API did not supply a grade
  (COALESCE(@Grade, dbo.fn_CalculateGrade(...))), so existing behaviour where
  C# computes the grade is unchanged.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_CalculateGrade (
    @SchoolId   INT,
    @Obtained   DECIMAL(10,2),
    @MaxMarks   DECIMAL(10,2)
)
RETURNS NVARCHAR(5)
AS
BEGIN
    IF @MaxMarks IS NULL OR @MaxMarks <= 0 OR @Obtained IS NULL
        RETURN NULL;

    DECLARE @Pct DECIMAL(10,4) = (@Obtained / @MaxMarks) * 100.0;

    DECLARE @APlus DECIMAL(10,2) = 90, @A DECIMAL(10,2) = 80, @B DECIMAL(10,2) = 70,
            @C     DECIMAL(10,2) = 60, @D DECIMAL(10,2) = 50, @E DECIMAL(10,2) = 40;

    SELECT @APlus = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdAPlus' THEN SettingValue END)),
           @A     = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdA'     THEN SettingValue END)),
           @B     = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdB'     THEN SettingValue END)),
           @C     = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdC'     THEN SettingValue END)),
           @D     = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdD'     THEN SettingValue END)),
           @E     = TRY_CONVERT(DECIMAL(10,2), MAX(CASE WHEN SettingKey = 'gradeThresholdE'     THEN SettingValue END))
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND Category = 'AcademicSettings'
      AND SettingKey IN ('gradeThresholdAPlus', 'gradeThresholdA', 'gradeThresholdB',
                         'gradeThresholdC', 'gradeThresholdD', 'gradeThresholdE');

    /* A missing or non-numeric setting must not blank out the grade. */
    SET @APlus = ISNULL(@APlus, 90);
    SET @A     = ISNULL(@A, 80);
    SET @B     = ISNULL(@B, 70);
    SET @C     = ISNULL(@C, 60);
    SET @D     = ISNULL(@D, 50);
    SET @E     = ISNULL(@E, 40);

    RETURN CASE
             WHEN @Pct >= @APlus THEN N'A+'
             WHEN @Pct >= @A     THEN N'A'
             WHEN @Pct >= @B     THEN N'B'
             WHEN @Pct >= @C     THEN N'C'
             WHEN @Pct >= @D     THEN N'D'
             WHEN @Pct >= @E     THEN N'E'
             ELSE N'F'
           END;
END
GO

/*==============================================================================
  fn_DayName -- 1..7 -> Monday..Sunday.

  Every schedule procedure used to inline the same seven-branch CASE. Centralised
  so the names cannot drift between procedures.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_DayName (@DayOfWeek INT)
RETURNS NVARCHAR(10)
AS
BEGIN
    RETURN CASE @DayOfWeek
             WHEN 1 THEN N'Monday'
             WHEN 2 THEN N'Tuesday'
             WHEN 3 THEN N'Wednesday'
             WHEN 4 THEN N'Thursday'
             WHEN 5 THEN N'Friday'
             WHEN 6 THEN N'Saturday'
             WHEN 7 THEN N'Sunday'
             ELSE NULL
           END;
END
GO

/*==============================================================================
  fn_SchoolCode -- SchoolId -> code. Convenience for the registration procs.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_SchoolCode (@SchoolId INT)
RETURNS NVARCHAR(12)
AS
BEGIN
    RETURN (SELECT SchoolCode FROM dbo.Schools WHERE Id = @SchoolId);
END
GO

/*==============================================================================
  fn_AcademicYear -- the academic year a date belongs to for a given school.

  A school whose year starts in April treats 2026-02-10 as academic year 2025.
  Used so admission numbers do not roll over in the middle of a session.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_AcademicYear (@SchoolId INT, @AsOf DATE)
RETURNS INT
AS
BEGIN
    DECLARE @StartMonth INT = (SELECT AcademicYearStartMonth FROM dbo.Schools WHERE Id = @SchoolId);
    SET @StartMonth = ISNULL(@StartMonth, 1);
    SET @AsOf = ISNULL(@AsOf, CAST(GETDATE() AS DATE));

    RETURN CASE WHEN MONTH(@AsOf) >= @StartMonth THEN YEAR(@AsOf) ELSE YEAR(@AsOf) - 1 END;
END
GO

/*==============================================================================
  sp_AssertSchool -- fail closed on a bad or inactive tenant.

  Called at the top of the write procedures. Without it, @SchoolId = 0 (the
  value a buggy or missing JWT claim produces) would silently match nothing and
  writes would fail with a confusing FK error instead of a clear message.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssertSchool
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @SchoolId IS NULL OR @SchoolId <= 0
    BEGIN
        THROW 51000, 'SchoolId is required. The tenant could not be resolved from the token.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
    BEGIN
        THROW 51001, 'School not found.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId AND IsActive = 1)
    BEGIN
        THROW 51002, 'This school is inactive.', 1;
    END
END
GO

/*==============================================================================
  sp_GetTeacherByUserId -- translate a logged-in Users.Id to a Teachers.Id.

  BREAKING CHANGE HELPER: TeacherSchedule.TeacherId and
  TeacherSubjectAssignments.TeacherId used to hold Users.Id while
  TeacherSubjects.TeacherId held Teachers.Id, so joins between them were wrong.
  All three now hold Teachers.Id, and every procedure taking @TeacherId means
  Teachers.Id. The API resolves it once with this procedure.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherByUserId
    @SchoolId INT,
    @UserId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id AS TeacherId,
           t.UserId,
           t.EmployeeId,
           u.FirstName,
           u.LastName,
           t.IsActive
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = t.SchoolId
           AND u.Id = t.UserId
    WHERE t.SchoolId = @SchoolId
      AND t.UserId = @UserId;
END
GO

/*==============================================================================
  SECTION -- IDENTITY HELPERS (Roles / Persons / Addresses)

  Added with the Users -> Users + Persons + Addresses split. Every procedure that
  writes a person goes through sp_UpsertPerson / sp_UpsertAddress rather than
  touching the tables directly, so the audit columns and the tenant checks are
  applied in exactly one place.
==============================================================================*/

/*==============================================================================
  fn_RoleId -- role name OR role code -> Roles.Id. NULL if no such role.

  Accepts either spelling so a caller can pass the JWT's 'Teacher' or the
  database's 'TEACHER' without knowing which it holds.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_RoleId (@Role NVARCHAR(50))
RETURNS INT
AS
BEGIN
    SET @Role = NULLIF(LTRIM(RTRIM(ISNULL(@Role, N''))), N'');
    IF @Role IS NULL RETURN NULL;

    RETURN (SELECT TOP (1) Id
            FROM dbo.Roles
            WHERE IsActive = 1
              AND (RoleName = @Role OR RoleCode = @Role)
            ORDER BY Id);
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

PRINT '=== 02_Functions.sql complete ===';
GO

SET NOEXEC OFF;
GO
