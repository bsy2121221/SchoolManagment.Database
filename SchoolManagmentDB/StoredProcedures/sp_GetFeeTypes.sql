/*==============================================================================
  StoredProcedure : dbo.sp_GetFeeTypes
  Extracted from: 11_Procs_Fees.sql
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
  sp_GetFeeTypes
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetFeeTypes
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, FeeTypeName, Description, DefaultAmount, IsActive, SchoolId
    FROM dbo.FeeTypes
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY FeeTypeName;
END
GO

SET NOEXEC OFF;
GO
