/*==============================================================================
  StoredProcedure : dbo.sp_GetClassAttendance
  Extracted from: 09_Procs_Attendance.sql
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
  sp_GetClassAttendance -- the register for one date.

  Driven from Students with a LEFT JOIN, so students with nothing marked yet
  appear with a NULL IsPresent. The old INNER JOIN from Attendance returned only
  already-marked students, which made a freshly opened register look empty and
  hid anyone the teacher had skipped.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetClassAttendance
    @SchoolId       INT,
    @ClassId        INT,
    @AttendanceDate DATE
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.Id,
           s.Id AS StudentId,
           a.IsPresent,
           a.Remarks,
           a.MarkedAt,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           u.Email
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Attendance AS a
           ON a.SchoolId = s.SchoolId
          AND a.StudentId = s.Id
          AND a.AttendanceDate = @AttendanceDate
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
