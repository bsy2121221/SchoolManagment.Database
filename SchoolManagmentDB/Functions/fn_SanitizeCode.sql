/*==============================================================================
  Function : dbo.fn_SanitizeCode
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

SET NOEXEC OFF;
GO
