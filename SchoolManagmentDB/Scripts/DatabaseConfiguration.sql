/*==============================================================================
  Scripts/DatabaseConfiguration.sql
  Baseline database options for SchoolManagementDB.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: run against SchoolManagementDB (sqlcmd -d SchoolManagementDB). ***';
    SET NOEXEC ON;
END
GO

ALTER DATABASE CURRENT SET RECOVERY SIMPLE;          -- change to FULL in production
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

PRINT '=== DatabaseConfiguration.sql complete ===';
GO

SET NOEXEC OFF;
GO