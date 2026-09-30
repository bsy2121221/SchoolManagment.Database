/*==============================================================================
  StoredProcedure : dbo.sp_UpdateUserStatus
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
  sp_UpdateUserStatus -- the name UserRepository.UpdateUserStatusAsync calls.

  Another procedure the repository referenced but that was never defined. Passes
  straight through to sp_ToggleUserStatus.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateUserStatus
    @SchoolId   INT,
    @UserId     INT,
    @IsActive   BIT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_ToggleUserStatus
        @SchoolId  = @SchoolId,
        @UserId    = @UserId,
        @IsActive  = @IsActive,
        @UpdatedBy = @ModifiedBy;
END
GO

SET NOEXEC OFF;
GO
