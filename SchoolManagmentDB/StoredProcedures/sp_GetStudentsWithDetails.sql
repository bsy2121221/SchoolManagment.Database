/*==============================================================================
  StoredProcedure : dbo.sp_GetStudentsWithDetails
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
  sp_GetStudentsWithDetails

  The class join is a LEFT JOIN now. The old INNER JOIN silently hid every
  student who had not been placed in a class yet.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetStudentsWithDetails
    @SchoolId   INT,
    @ClassId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.FatherName,
           s.MotherName,
           s.BloodGroup,
           s.AdmissionDate,
           s.IsActive,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           c.Id AS ClassId,
           c.ClassName,
           c.Grade,
           c.Section,
           s.SchoolId
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Classes AS c ON c.SchoolId = s.SchoolId AND c.Id = s.ClassId
    WHERE s.SchoolId = @SchoolId
      AND (@ClassId IS NULL OR s.ClassId = @ClassId)
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY c.Grade, c.Section, s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
