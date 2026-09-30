/*==============================================================================
  Function : dbo.fn_CalculateGrade
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

SET NOEXEC OFF;
GO
