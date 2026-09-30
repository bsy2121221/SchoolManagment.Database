/*==============================================================================
  StoredProcedure : dbo.sp_GetAvailableTeachers
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
  sp_GetAvailableTeachers -- pick list for "class teacher".

  Id is now Teachers.Id, because that is what Classes.ClassTeacherId stores.
  The old version returned Users.Id here, so the value the UI sent back as
  ClassTeacherId pointed at the wrong table. UserId is returned alongside for
  screens that need it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetAvailableTeachers
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           u.Id AS UserId,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           (SELECT COUNT(*) FROM dbo.Classes AS c
             WHERE c.SchoolId = t.SchoolId AND c.ClassTeacherId = t.Id AND c.IsActive = 1) AS CurrentClasses
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    WHERE t.SchoolId = @SchoolId
      AND u.RoleId = 3          -- Teacher
      AND u.IsActive = 1
      AND t.IsActive = 1
    ORDER BY u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
