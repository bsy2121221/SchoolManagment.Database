/*==============================================================================
  Function : dbo.fn_AcademicYear
  Extracted from: 02_Functions.sql
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
  fn_AcademicYear -- the academic year a date belongs to for a given school.

  A school whose year starts in April treats 2026-02-10 as academic year 2025.
  Used so admission numbers do not roll over in the middle of a session.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_AcademicYear (@SchoolId INT, @AsOf DATE)
RETURNS INT
AS
BEGIN
    DECLARE @StartMonth INT = (SELECT AcademicYearStartMonth FROM dbo.Schools WHERE Id = @SchoolId);
    SET @StartMonth = ISNULL(@StartMonth, 1);
    SET @AsOf = ISNULL(@AsOf, CAST(GETDATE() AS DATE));

    RETURN CASE WHEN MONTH(@AsOf) >= @StartMonth THEN YEAR(@AsOf) ELSE YEAR(@AsOf) - 1 END;
END
GO

/*==============================================================================
  sp_AssertSchool -- fail closed on a bad or inactive tenant.

  Called at the top of the write procedures. Without it, @SchoolId = 0 (the
  value a buggy or missing JWT claim produces) would silently match nothing and
  writes would fail with a confusing FK error instead of a clear message.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssertSchool
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @SchoolId IS NULL OR @SchoolId <= 0
    BEGIN
        THROW 51000, 'SchoolId is required. The tenant could not be resolved from the token.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
    BEGIN
        THROW 51001, 'School not found.', 1;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId AND IsActive = 1)
    BEGIN
        THROW 51002, 'This school is inactive.', 1;
    END
END
GO

/*==============================================================================
  sp_GetTeacherByUserId -- translate a logged-in Users.Id to a Teachers.Id.

  BREAKING CHANGE HELPER: TeacherSchedule.TeacherId and
  TeacherSubjectAssignments.TeacherId used to hold Users.Id while
  TeacherSubjects.TeacherId held Teachers.Id, so joins between them were wrong.
  All three now hold Teachers.Id, and every procedure taking @TeacherId means
  Teachers.Id. The API resolves it once with this procedure.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetTeacherByUserId
    @SchoolId INT,
    @UserId   INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.Id AS TeacherId,
           t.UserId,
           t.EmployeeId,
           u.FirstName,
           u.LastName,
           t.IsActive
    FROM dbo.Teachers AS t
    INNER JOIN dbo.vw_Users AS u
            ON u.SchoolId = t.SchoolId
           AND u.Id = t.UserId
    WHERE t.SchoolId = @SchoolId
      AND t.UserId = @UserId;
END
GO

/*==============================================================================
  SECTION -- IDENTITY HELPERS (Roles / Persons / Addresses)

  Added with the Users -> Users + Persons + Addresses split. Every procedure that
  writes a person goes through sp_UpsertPerson / sp_UpsertAddress rather than
  touching the tables directly, so the audit columns and the tenant checks are
  applied in exactly one place.
==============================================================================*/

SET NOEXEC OFF;
GO
