/*==============================================================================
  StoredProcedure : dbo.sp_LogAudit
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
  sp_LogAudit -- append an activity row.

  The activity feeds (sp_GetUserActivityLog, sp_GetProfileActivities) used to be
  reconstructed from CreatedAt columns because no audit table existed. They now
  read real events written here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LogAudit
    @SchoolId   INT = NULL,
    @UserId     INT = NULL,
    @Action     NVARCHAR(100),
    @EntityType NVARCHAR(50) = NULL,
    @EntityId   INT = NULL,
    @Details    NVARCHAR(1000) = NULL,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AuditLog (SchoolId, UserId, Action, EntityType, EntityId, Details, IpAddress)
    VALUES (@SchoolId, @UserId, @Action, @EntityType, @EntityId, @Details, @IpAddress);
END
GO

SET NOEXEC OFF;
GO
