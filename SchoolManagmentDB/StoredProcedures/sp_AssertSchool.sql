/*==============================================================================
  StoredProcedure : dbo.sp_AssertSchool
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
  sp_AssertSchool -- fail closed on a bad or inactive tenant.

  Called at the top of the write procedures. Without it, @SchoolId = 0 (the
  value a buggy or missing JWT claim produces) would silently match nothing and
  writes would fail with a confusing FK error instead of a clear message.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssertSchool
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @SchoolId IS NULL OR @SchoolId <= 0
    BEGIN
        THROW 51000, 'SchoolId is required. The tenant could not be resolved from the token.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
    BEGIN
        THROW 51001, 'School not found.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId AND IsActive = 1)
    BEGIN
        THROW 51002, 'This school is inactive.', 1;
    END
END
GO

SET NOEXEC OFF;
GO
