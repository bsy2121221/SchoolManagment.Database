/*==============================================================================
  Function : dbo.fn_GenerateParentUsername
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
  fn_GenerateParentUsername -- DPSNOIDA_P_RSHARMA01

  Same construction as fn_GenerateTeacherUsername, with a _P_ marker and its own
  per-school 'Parent' counter, so a parent and a teacher of the same name cannot
  collide on Users.Username.

  It replaces what ParentRepository.RegisterParentAsync did in C#:

      var username = $"{emailPrefix}_{random.Next(1000, 9999)}";
      while (usernameExists) { re-roll; re-read; }

  which is the read-then-write race this file exists to remove, leaked a mailbox
  name into a credential, and could in principle never terminate. The suffix here
  is a claimed sequence value, so two admins registering at once get two numbers.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_GenerateParentUsername (
    @SchoolCode NVARCHAR(12),
    @FirstName  NVARCHAR(50),
    @LastName   NVARCHAR(50),
    @Seq        INT
)
RETURNS NVARCHAR(80)
AS
BEGIN
    DECLARE @First NVARCHAR(50) = dbo.fn_SanitizeCode(@FirstName);
    DECLARE @Last  NVARCHAR(50) = dbo.fn_SanitizeCode(@LastName);

    DECLARE @Base NVARCHAR(30) = LEFT(ISNULL(LEFT(@First, 1), N'') + @Last, 20);
    IF @Base = N'' SET @Base = N'PARENT';

    RETURN UPPER(@SchoolCode) + N'_P_' + @Base
         + RIGHT(N'00' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 99 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 2 END);
END
GO

SET NOEXEC OFF;
GO
