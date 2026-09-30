/*==============================================================================
  Function : dbo.fn_GenerateStudentUsername
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

SET NOEXEC OFF;
GO
