/*==============================================================================
  Function : dbo.fn_GenerateTeacherUsername
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

SET NOEXEC OFF;
GO
