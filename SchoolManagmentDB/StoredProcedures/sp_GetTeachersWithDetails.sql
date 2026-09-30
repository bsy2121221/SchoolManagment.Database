/*==============================================================================
  StoredProcedure : dbo.sp_GetTeachersWithDetails
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
  sp_GetTeachersWithDetails

  @SubjectId now filters with EXISTS instead of inside the WHERE of the
  aggregation. The old form dropped every OTHER subject from SubjectNames when
  the filter was supplied, so a filtered list showed teachers as if they taught
  only one subject.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeachersWithDetails
    @SchoolId   INT,
    @SubjectId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id,
           t.EmployeeId,
           t.Subject,
           t.Qualification,
           t.Experience,
           t.Salary,
           t.JoinDate,
           t.IsActive,
           u.Id AS UserId,
           u.Username,
           u.Email,
           u.FirstName,
           u.LastName,
           u.PhoneNumber,
           u.Address,
           u.RequirePasswordChange,
           STRING_AGG(s.SubjectName, ', ') AS SubjectNames,
           STRING_AGG(CAST(s.Id AS NVARCHAR(10)), ',') AS SubjectIds,
           t.SchoolId
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
    LEFT JOIN dbo.TeacherSubjects AS ts
           ON ts.SchoolId = t.SchoolId AND ts.TeacherId = t.Id AND ts.IsActive = 1
    LEFT JOIN dbo.Subjects AS s
           ON s.SchoolId = ts.SchoolId AND s.Id = ts.SubjectId
    WHERE t.SchoolId = @SchoolId
      AND t.IsActive = 1
      AND u.IsActive = 1
      AND (@SubjectId IS NULL
           OR EXISTS (SELECT 1 FROM dbo.TeacherSubjects AS f
                       WHERE f.SchoolId = t.SchoolId AND f.TeacherId = t.Id
                         AND f.SubjectId = @SubjectId AND f.IsActive = 1))
    GROUP BY t.Id, t.EmployeeId, t.Subject, t.Qualification, t.Experience, t.Salary,
             t.JoinDate, t.IsActive, u.Id, u.Username, u.Email, u.FirstName, u.LastName,
             u.PhoneNumber, u.Address, u.RequirePasswordChange, t.SchoolId
    ORDER BY t.JoinDate DESC;
END
GO

SET NOEXEC OFF;
GO
