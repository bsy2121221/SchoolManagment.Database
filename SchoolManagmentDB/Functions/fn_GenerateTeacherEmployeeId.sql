/*==============================================================================
  Function : dbo.fn_GenerateTeacherEmployeeId
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

SET NOEXEC OFF;
GO
