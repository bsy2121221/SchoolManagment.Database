/*==============================================================================
  Function : dbo.fn_SchoolCode
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
  fn_SchoolCode -- SchoolId -> code. Convenience for the registration procs.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_SchoolCode (@SchoolId INT)
RETURNS NVARCHAR(12)
AS
BEGIN
    RETURN (SELECT SchoolCode FROM dbo.Schools WHERE Id = @SchoolId);
END
GO

SET NOEXEC OFF;
GO
