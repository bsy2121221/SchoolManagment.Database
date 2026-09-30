/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentsByClass
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
  sp_GetStudentsByClass -- NEW. Unpaged roster behind GET /students/by-class/{id}.

  Not the same thing as sp_GetStudentsForClass, which stays as the lightweight
  feed for the attendance and grade-entry screens. This one returns the full
  StudentDTO shape because that is what the endpoint is declared to return, and
  it is the picker feed for anything that has to choose a student in one class.

  Active students only by default: a roster is who is in the room.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsByClass
    @SchoolId        INT,
    @ClassId         INT,
    @IncludeInactive BIT = 0
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
      AND s.ClassId = @ClassId
      AND (@IncludeInactive = 1 OR s.IsActive = 1)
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber, u.FirstName, u.LastName;
END
GO

SET NOEXEC OFF;
GO
