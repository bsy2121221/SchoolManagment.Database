/*==============================================================================
  StoredProcedure : dbo.sp_GetProfileActivities
  Extracted from: 14_Procs_Dashboard.sql
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
  sp_GetProfileActivities -- the signed-in user's own recent activity.

  Column names kept: ActivityType, ActivityDate, ActivityDescription.
  EntityType / EntityId / IpAddress follow, matching sp_GetUserActivityLog.

  @SchoolId is optional so a SuperAdmin (SchoolId NULL, and therefore
  AuditLog.SchoolId NULL on their platform actions) can read their own history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetProfileActivities
    @SchoolId   INT = NULL,
    @UserId     INT,
    @TopCount   INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    /* A caller passing @TopCount = 0 or a negative number used to get an
       immediate error out of TOP; clamp instead. */
    SET @TopCount = CASE WHEN ISNULL(@TopCount, 10) BETWEEN 1 AND 500 THEN @TopCount ELSE 10 END;

    SELECT TOP (@TopCount)
           al.Action AS ActivityType,
           al.CreatedAt AS ActivityDate,
           CASE
               WHEN al.Details IS NOT NULL THEN al.Action + ': ' + al.Details
               WHEN al.EntityType IS NOT NULL THEN al.Action + ' on ' + al.EntityType
               ELSE al.Action
           END AS ActivityDescription,
           al.EntityType,
           al.EntityId,
           al.IpAddress
    FROM dbo.AuditLog AS al
    WHERE al.UserId = @UserId
      AND (@SchoolId IS NULL OR al.SchoolId = @SchoolId)
    ORDER BY al.CreatedAt DESC;
END
GO

SET NOEXEC OFF;
GO
