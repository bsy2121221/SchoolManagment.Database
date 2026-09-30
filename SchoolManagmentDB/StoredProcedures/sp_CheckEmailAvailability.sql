/*==============================================================================
  StoredProcedure : dbo.sp_CheckEmailAvailability
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
  sp_CheckEmailAvailability -- Returns: IsAvailable, Message

  Scoped to the school: UQ_Users_School_Email means the same address may exist
  once per school. @SchoolId NULL is the platform scope (SuperAdmin), which is
  compared against the other SchoolId NULL users rather than against everybody.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CheckEmailAvailability
    @SchoolId   INT = NULL,
    @UserId     INT,
    @Email      NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1
                 FROM dbo.Users
                WHERE Email = @Email
                  AND Id <> @UserId
                  AND ((SchoolId = @SchoolId) OR (@SchoolId IS NULL AND SchoolId IS NULL)))
        SELECT CAST(0 AS BIT) AS IsAvailable,
               'Email already in use by another user' AS Message;
    ELSE
        SELECT CAST(1 AS BIT) AS IsAvailable,
               'Email is available' AS Message;
END
GO

SET NOEXEC OFF;
GO
