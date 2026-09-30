/*==============================================================================
  StoredProcedure : dbo.sp_GetAllSubjectsForTeacher
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
  sp_GetAllSubjectsForTeacher -- the pick list on the registration form.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAllSubjectsForTeacher
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND IsActive = 1
    ORDER BY TRY_CONVERT(INT, Grade), Grade, SubjectName;
END
GO

SET NOEXEC OFF;
GO
