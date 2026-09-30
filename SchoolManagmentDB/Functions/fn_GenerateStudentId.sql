/*==============================================================================
  Function : dbo.fn_GenerateStudentId
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

SET NOEXEC OFF;
GO
