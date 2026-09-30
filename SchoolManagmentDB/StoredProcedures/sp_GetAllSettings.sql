/*==============================================================================
  StoredProcedure : dbo.sp_GetAllSettings
  Extracted from: 13_Procs_Settings.sql
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
  sp_GetAllSettings
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSettings
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id,
           Category,
           SettingKey,
           SettingValue,
           DataType,
           Description,
           IsActive,
           CreatedAt,
           UpdatedAt,
           CreatedBy,
           UpdatedBy,
           SchoolId
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY Category, SettingKey;
END
GO

SET NOEXEC OFF;
GO
