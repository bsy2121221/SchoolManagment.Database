/*==============================================================================
  StoredProcedure : dbo.sp_RecordLogin
  Extracted from: 04_Procs_Auth.sql
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
  sp_RecordLogin -- stamp LastLoginAt and write an audit row.

  Separate from sp_Login because the API calls sp_Login BEFORE verifying the
  password hash; stamping there would record every failed attempt as a login.
  Call this from AuthController after BCrypt.Verify succeeds.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RecordLogin
    @UserId     INT,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolId INT = (SELECT SchoolId FROM dbo.Users WHERE Id = @UserId);

    UPDATE dbo.Users
       SET LastLoginAt = GETDATE()
     WHERE Id = @UserId;

    EXEC dbo.sp_LogAudit
        @SchoolId = @SchoolId, @UserId = @UserId,
        @Action = 'Auth.Login', @EntityType = 'User', @EntityId = @UserId,
        @IpAddress = @IpAddress;
END
GO

SET NOEXEC OFF;
GO
