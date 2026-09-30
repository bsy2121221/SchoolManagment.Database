/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentById
  Extracted from: 06_Procs_Students.sql
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
  sp_GetStudentById -- NEW. The single read behind GET /api/Students/{id}.

  @IncludeInactive defaults to 1, as for sp_GetSubjectById and unlike
  sp_GetClassById: the list this is opened from can show deactivated students, so
  404ing on a row the user just clicked would be the bug, not the safeguard.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentById
    @SchoolId        INT,
    @StudentId       INT,          -- Students.Id, not the admission number
    @IncludeInactive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.UserId,
           s.StudentId,
           u.Username,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.ClassId,
           c.ClassName,
           s.RollNumber,
           s.DateOfBirth,
           s.Gender,
           s.FatherName,
           s.MotherName,
           s.AdmissionDate,
           s.BloodGroup,
           u.Address,
           s.IsActive,
           s.CreatedAt,
           s.UpdatedAt,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND s.Id = @StudentId
      AND (@IncludeInactive = 1 OR s.IsActive = 1);
END
GO

SET NOEXEC OFF;
GO
