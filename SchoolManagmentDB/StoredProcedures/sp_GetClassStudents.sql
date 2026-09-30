/*==============================================================================
  StoredProcedure : dbo.sp_GetClassStudents
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
  sp_GetClassStudents
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassStudents
    @SchoolId   INT,
    @ClassId    INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.Id,
           s.StudentId,
           s.RollNumber,
           s.DateOfBirth,
           s.AdmissionDate,
           u.Id AS UserId,
           u.FirstName,
           u.LastName,
           u.Email,
           u.PhoneNumber,
           s.FatherName,
           s.MotherName,
           s.BloodGroup
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
