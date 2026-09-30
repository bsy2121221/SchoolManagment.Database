/*==============================================================================
  StoredProcedure : dbo.sp_PreviewTeacherUsername
  Extracted from: 07_Procs_Teachers.sql
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
  sp_PreviewTeacherUsername -- peeks the sequence, does not consume it.

  Returns: GeneratedUsername, GeneratedEmployeeId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_PreviewTeacherUsername
    @SchoolId   INT,
    @FirstName  NVARCHAR(50),
    @LastName   NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);
    DECLARE @Seq INT;

    EXEC dbo.sp_PeekSequence @SchoolId = @SchoolId, @SequenceName = N'Employee', @NextValue = @Seq OUTPUT;

    SELECT dbo.fn_GenerateTeacherUsername(@Code, @FirstName, @LastName, @Seq) AS GeneratedUsername,
           dbo.fn_GenerateTeacherEmployeeId(@Code, @Seq) AS GeneratedEmployeeId;
END
GO

SET NOEXEC OFF;
GO
