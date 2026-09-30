/*==============================================================================
  StoredProcedure : dbo.sp_GetClassById
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
  sp_GetClassById

  ClassTeacher/StudentCount renamed to ClassTeacherName/TotalStudents to match
  ClassDTO, and UpdatedAt added -- without it the API returned 0001-01-01 for
  every class, which a client cannot tell from a real timestamp.

  ClassTeacherEmail and ClassTeacherPhone are not on ClassDTO and so go nowhere.
  Kept because this is also the single-class read for any future detail view, and
  dropping columns is the change that silently empties a screen later.

  @IncludeInactive exists for sp_GetClassDetails: a soft-deleted class must still
  be openable, or an administrator cannot see what is occupying a grade+section
  that sp_CreateClass keeps refusing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassById
    @SchoolId         INT,
    @ClassId          INT,
    @IncludeInactive  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT c.Id,
           c.ClassName,
           c.Grade,
           c.Section,
           c.MaxStudents,
           c.IsActive,
           c.CreatedAt,
           c.UpdatedAt,
           c.ClassTeacherId,
           CASE WHEN c.ClassTeacherId IS NOT NULL
                THEN CONCAT(u.FirstName, ' ', u.LastName)
                ELSE NULL END AS ClassTeacherName,
           u.Email AS ClassTeacherEmail,
           u.PhoneNumber AS ClassTeacherPhone,
           COUNT(s.Id) AS TotalStudents,
           c.SchoolId
    FROM dbo.Classes AS c
    LEFT JOIN dbo.Teachers AS t ON t.SchoolId = c.SchoolId AND t.Id = c.ClassTeacherId
    LEFT JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id AND s.IsActive = 1
    WHERE c.SchoolId = @SchoolId
      AND c.Id = @ClassId
      AND (@IncludeInactive = 1 OR c.IsActive = 1)
    GROUP BY c.Id, c.ClassName, c.Grade, c.Section, c.MaxStudents, c.IsActive, c.CreatedAt,
             c.UpdatedAt, c.ClassTeacherId, u.FirstName, u.LastName, u.Email, u.PhoneNumber,
             c.SchoolId;
END
GO

SET NOEXEC OFF;
GO
