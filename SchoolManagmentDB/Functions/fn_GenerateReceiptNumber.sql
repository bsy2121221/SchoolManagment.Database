/*==============================================================================
  Function : dbo.fn_GenerateReceiptNumber
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

SET NOEXEC OFF;
GO
