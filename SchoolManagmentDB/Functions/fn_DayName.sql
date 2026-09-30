/*==============================================================================
  Function : dbo.fn_DayName
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

SET NOEXEC OFF;
GO
