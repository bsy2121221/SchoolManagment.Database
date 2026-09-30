/*==============================================================================
  StoredProcedure : dbo.sp_GetUserActivityLog
  Extracted from: 05_Procs_Users.sql
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
  sp_GetUserActivityLog -- Returns: ActivityType, ActivityDate, ActivityDescription

  The old version faked this feed: it UNIONed Users.UpdatedAt three times, so
  "Login Activity" and "Profile Update" always showed the same timestamp and
  nothing was real history. It reads the AuditLog table now.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserActivityLog
    @SchoolId   INT,
    @UserId     INT,
    @TopCount   INT = 10
AS
BEGIN
    SET NOCOUNT ON;

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
    WHERE al.SchoolId = @SchoolId
      AND al.UserId = @UserId
    ORDER BY al.CreatedAt DESC;
END
GO

SET NOEXEC OFF;
GO
