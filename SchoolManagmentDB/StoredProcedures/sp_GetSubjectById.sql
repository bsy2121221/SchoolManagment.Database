/*==============================================================================
  StoredProcedure : dbo.sp_GetSubjectById
  Extracted from: 10_Procs_Academics.sql
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
  sp_GetSubjectById -- NEW.

  @IncludeInactive defaults to 1, the opposite of sp_GetClassById. This is the
  read behind the edit and status screens, and the list they are opened from can
  show deactivated subjects: 404ing on a row the user just clicked would be a
  bug, and reactivating one would be impossible.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSubjectById
    @SchoolId         INT,
    @SubjectId        INT,
    @IncludeInactive  BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id, SubjectName, SubjectCode, Grade, IsActive, CreatedAt, UpdatedAt, SchoolId
    FROM dbo.Subjects
    WHERE SchoolId = @SchoolId
      AND Id = @SubjectId
      AND (@IncludeInactive = 1 OR IsActive = 1);
END
GO

SET NOEXEC OFF;
GO
