/*==============================================================================
  StoredProcedure : dbo.sp_GetClassDetails
  Extracted from: 08_Procs_Classes.sql
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
  sp_GetClassDetails -- Returns three result sets: class, students, stats.

  New. ClassRepository.GetClassDetailsAsync has always called this and read three
  result sets from it, so GET /api/Classes/{id}/details failed with "Could not
  find stored procedure".

  One round trip instead of three, and -- more to the point -- one consistent
  read: with three separate calls the student list can change between the list and
  the count that is supposed to describe it.

  @IncludeInactive = 1 on the class read, because a details page is how you find
  out *why* a class is suspended. An empty first result set is the signal that the
  class does not exist; the repository returns null on it and the controller 404s.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassDetails
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_GetClassById  @SchoolId = @SchoolId, @ClassId = @ClassId, @IncludeInactive = 1;
    EXEC dbo.sp_GetClassStudents @SchoolId = @SchoolId, @ClassId = @ClassId;
    EXEC dbo.sp_GetClassStats @SchoolId = @SchoolId, @ClassId = @ClassId;
END
GO

SET NOEXEC OFF;
GO
