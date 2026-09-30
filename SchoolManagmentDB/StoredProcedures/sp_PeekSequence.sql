/*==============================================================================
  StoredProcedure : dbo.sp_PeekSequence
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

SET NOEXEC OFF;
GO
