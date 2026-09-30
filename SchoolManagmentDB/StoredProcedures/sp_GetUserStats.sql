/*==============================================================================
  StoredProcedure : dbo.sp_GetUserStats
  Extracted from: 05_Procs_Users.sql
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
  sp_GetUserStats -- role-dependent counters for the profile page.

  Two fixes carried over from the old version:
    * teacher stats keyed off Classes.ClassTeacherId = @UserId, but that column
      holds Teachers.Id; the user id is resolved first now.
    * the overdue-fee count used
          f.Id NOT IN (SELECT FeeId FROM FeePayments GROUP BY FeeId
                       HAVING SUM(AmountPaid) >= (SELECT Amount FROM Fees WHERE Id = FeeId))
      The inner correlation on FeeId inside a HAVING is fragile and cannot use
      an index. It is a LEFT JOIN over aggregated payments now.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetUserStats
    @SchoolId   INT,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RoleId INT;

    SELECT @RoleId = RoleId
    FROM dbo.Users
    WHERE Id = @UserId AND SchoolId = @SchoolId;

    IF @RoleId = 3   -- Teacher
    BEGIN
        DECLARE @TeacherId INT = (SELECT Id FROM dbo.Teachers
                                   WHERE SchoolId = @SchoolId AND UserId = @UserId);

        SELECT (SELECT COUNT(*) FROM dbo.Classes
                 WHERE SchoolId = @SchoolId AND ClassTeacherId = @TeacherId AND IsActive = 1) AS ClassesAssigned,

               (SELECT COUNT(DISTINCT s.Id)
                  FROM dbo.Classes AS c
                  INNER JOIN dbo.Students AS s ON s.SchoolId = c.SchoolId AND s.ClassId = c.Id
                 WHERE c.SchoolId = @SchoolId AND c.ClassTeacherId = @TeacherId
                   AND c.IsActive = 1 AND s.IsActive = 1) AS StudentsUnderCare,

               (SELECT COUNT(*) FROM dbo.TeacherSubjects
                 WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId AND IsActive = 1) AS SubjectsAssigned,

               (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND MarkedBy = @UserId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))) AS AttendanceMarkedLastMonth;
    END
    ELSE IF @RoleId = 4   -- Student
    BEGIN
        DECLARE @StudentId INT = (SELECT Id FROM dbo.Students
                                   WHERE SchoolId = @SchoolId AND UserId = @UserId);

        SELECT (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))
                   AND IsPresent = 1) AS PresentLastMonth,

               (SELECT COUNT(*) FROM dbo.Attendance
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId
                   AND AttendanceDate >= DATEADD(MONTH, -1, CAST(GETDATE() AS DATE))
                   AND IsPresent = 0) AS AbsentLastMonth,

               (SELECT COUNT(*) FROM dbo.Results
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalResults,

               (SELECT COUNT(*) FROM dbo.Fees
                 WHERE SchoolId = @SchoolId AND StudentId = @StudentId AND IsActive = 1) AS TotalFees,

               (SELECT COUNT(*)
                  FROM dbo.Fees AS f
                  LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                               FROM dbo.FeePayments
                              WHERE PaymentStatus = 'Completed'
                              GROUP BY SchoolId, FeeId) AS p
                         ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
                 WHERE f.SchoolId = @SchoolId
                   AND f.StudentId = @StudentId
                   AND f.IsActive = 1
                   AND f.DueDate < CAST(GETDATE() AS DATE)
                   AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees;
    END
    ELSE IF @RoleId = 5   -- Parent
    BEGIN
        SELECT (SELECT COUNT(*)
                  FROM dbo.StudentParents AS sp
                  INNER JOIN dbo.Parents AS p ON p.SchoolId = sp.SchoolId AND p.Id = sp.ParentId
                 WHERE p.SchoolId = @SchoolId AND p.UserId = @UserId AND sp.IsActive = 1) AS TotalChildren;
    END
    ELSE
    BEGIN
        SELECT 0 AS NoStats;
    END
END
GO

SET NOEXEC OFF;
GO
