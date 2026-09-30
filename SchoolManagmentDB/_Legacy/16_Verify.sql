/*==============================================================================
  16_Verify.sql  --  Self-checking test pass. Optional; not part of the schema.

  Run it directly after a clean 00 -> 15 on a SCRATCH database. It asserts the
  exact row counts 15_Seed.sql produces, so it only means anything on freshly
  seeded data.

  IT WRITES DATA: extra students, a school called VERIFY1, a changed grade
  threshold for STMARY, a custom role called Librarian, and one Persons row with
  no login (the probe for CK_Users_SchoolScope needs a person nobody owns).
  Rebuild from 00 afterwards. Never run it against a database anyone is using.

  Output is one row per check with PASS / **FAIL** and a summary line. It also
  prints the seeded read-procedure result sets along the way -- that noise is
  unavoidable, since the checks measure what those procedures return.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE SchoolCode = N'DPSNOIDA')
BEGIN
    PRINT '*** ABORTED: run 15_Seed.sql first; these checks assert its row counts. ***';
    SET NOEXEC ON;
END
GO

DECLARE @R TABLE (Ord INT IDENTITY(1,1), Chk NVARCHAR(120), Expected NVARCHAR(200),
                  Actual NVARCHAR(400), Pass BIT);

DECLARE @S1 INT = (SELECT Id FROM dbo.Schools WHERE SchoolCode = 'DPSNOIDA');
DECLARE @S2 INT = (SELECT Id FROM dbo.Schools WHERE SchoolCode = 'STMARY');

/*==========================================================================
  1. THE COMPOSITE FOREIGN KEYS MUST BITE

  Row-Level Security is not used, so these constraints are the only structural
  guarantee that one school's rows cannot reference another's. Each check asserts
  the specific constraint name, so a pass cannot come from some unrelated
  constraint firing first.
==========================================================================*/
DECLARE @Msg NVARCHAR(400), @Failed BIT;

/* A school-1 user who is NOT already a student, so the insert can only fail on
   the class FK and not on UQ_Students_UserId. */
DECLARE @U1  INT = (SELECT TOP 1 Id FROM dbo.Users WHERE SchoolId = @S1 AND RoleId = 2);  -- Admin
DECLARE @C1  INT = (SELECT TOP 1 Id FROM dbo.Classes  WHERE SchoolId = @S1);
DECLARE @C2  INT = (SELECT TOP 1 Id FROM dbo.Classes  WHERE SchoolId = @S2);
DECLARE @St1 INT = (SELECT TOP 1 Id FROM dbo.Students WHERE SchoolId = @S1);
DECLARE @St2 INT = (SELECT TOP 1 Id FROM dbo.Students WHERE SchoolId = @S2);
DECLARE @Ex2 INT = (SELECT TOP 1 Id FROM dbo.Examinations WHERE SchoolId = @S2);
DECLARE @Ft2 INT = (SELECT TOP 1 Id FROM dbo.FeeTypes WHERE SchoolId = @S2);
DECLARE @T1  INT = (SELECT TOP 1 Id FROM dbo.Teachers WHERE SchoolId = @S1);
DECLARE @Sub2 INT = (SELECT TOP 1 Id FROM dbo.Subjects WHERE SchoolId = @S2);

SET @Failed = 0;
BEGIN TRY
    INSERT INTO dbo.Students (SchoolId, UserId, StudentId, ClassId, AdmissionDate)
    VALUES (@S1, @U1, N'FKTEST1', @C2, GETDATE());
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 student into school 2 class', 'rejected by FK_Students_Class',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Students_Class%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    INSERT INTO dbo.Attendance (SchoolId, StudentId, ClassId, AttendanceDate, IsPresent, MarkedBy)
    VALUES (@S1, @St2, @C1, '2099-01-01', 1, @U1);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 2 student in school 1 attendance', 'rejected by FK_Attendance_Student',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Attendance_Student%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    INSERT INTO dbo.Results (SchoolId, StudentId, ExaminationId, ObtainedMarks)
    VALUES (@S1, @St1, @Ex2, 50);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 result against school 2 exam', 'rejected by FK_Results_Exam',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Results_Exam%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
    VALUES (@S1, @St1, @Ft2, 100, '2099-01-01', 1, 2099);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 fee using school 2 fee type', 'rejected by FK_Fees_FeeType',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Fees_FeeType%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    INSERT INTO dbo.TeacherSchedule (SchoolId, TeacherId, SubjectId, ClassId, DayOfWeek, StartTime, EndTime)
    VALUES (@S1, @T1, @Sub2, @C1, 6, '17:00', '17:45');
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 schedule using school 2 subject', 'rejected by FK_TeacherSchedule_Subject',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_TeacherSchedule_Subject%' THEN 1 ELSE 0 END);

/* A person with no login of their own, so the Users insert below can only fail
   on the CHECK and not on UQ_Users_PersonId. */
DECLARE @OrphanPerson INT;
INSERT INTO dbo.Persons (SchoolId, FirstName, LastName)
VALUES (@S1, N'Constraint', N'Probe');
SET @OrphanPerson = CAST(SCOPE_IDENTITY() AS INT);

SET @Failed = 0;
BEGIN TRY
    /* RoleId 2 is Admin, so SchoolId NULL is illegal. FK_Users_Person is composite
       on (SchoolId, PersonId) and SQL Server skips a composite FK when any of its
       columns is NULL, which is precisely why the CHECK has to exist. */
    INSERT INTO dbo.Users (SchoolId, PersonId, Username, Email, PasswordHash, RoleId)
    VALUES (NULL, @OrphanPerson, N'FKTEST_ADMIN', N'fk@test.local', N'x', 2);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('CHECK: only a SuperAdmin may have SchoolId NULL', 'rejected by CK_Users_SchoolScope',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%CK_Users_SchoolScope%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    /* The mirror case: a school-1 login pointing at a school-2 person. Here both
       FK columns are non-NULL, so the composite FK does bite. */
    DECLARE @Person2 INT = (SELECT TOP 1 p.Id FROM dbo.Persons AS p WHERE p.SchoolId = @S2 ORDER BY p.Id);

    INSERT INTO dbo.Users (SchoolId, PersonId, Username, Email, PasswordHash, RoleId)
    VALUES (@S1, @Person2, N'FKTEST_CROSS', N'cross@test.local', N'x', 2);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 login onto a school 2 person', 'rejected by FK_Users_Person',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Users_Person%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    /* Same guard one table further out: an address filed against another school's
       person. This is the constraint that keeps a home address from leaking. */
    INSERT INTO dbo.Addresses (SchoolId, PersonId, AddressType, AddressLine1)
    VALUES (@S1, (SELECT TOP 1 Id FROM dbo.Persons WHERE SchoolId = @S2 ORDER BY Id),
            N'Current', N'1 Cross Tenant Road');
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('FK: school 1 address onto a school 2 person', 'rejected by FK_Addresses_Person',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%FK_Addresses_Person%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    /* Fail-closed rule from CK_RolePermissions_ViewImplied: no delete right
       without the right to see what you are deleting. */
    INSERT INTO dbo.RolePermissions (RoleId, ModuleName, CanView, CanDelete)
    VALUES (2, N'CKProbeModule', 0, 1);
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('CHECK: no create/edit/delete without CanView', 'rejected by CK_RolePermissions_ViewImplied',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%CK_RolePermissions_ViewImplied%' THEN 1 ELSE 0 END);

SET @Failed = 0;
BEGIN TRY
    /* Custom roles must land at 100+, so a future system role can be added at
       6..99 without colliding with anything a customer created. */
    INSERT INTO dbo.Roles (Id, RoleName, RoleCode)
    VALUES (6, N'CK Probe Role', N'CKPROBE');
END TRY BEGIN CATCH SET @Failed = 1; SET @Msg = ERROR_MESSAGE(); END CATCH
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('CHECK: role ids are 1-5 or 100+', 'rejected by CK_Roles_Id',
        CASE WHEN @Failed = 1 THEN LEFT(@Msg, 380) ELSE 'ACCEPTED (leak!)' END,
        CASE WHEN @Failed = 1 AND @Msg LIKE '%CK_Roles_Id%' THEN 1 ELSE 0 END);

/*==========================================================================
  2. READ PROCEDURES RETURN ONE SCHOOL'S ROWS ONLY

  @@ROWCOUNT after EXEC is the row count of the procedure's final SELECT, so a
  procedure that forgot a SchoolId filter shows up here as the combined total.
==========================================================================*/
DECLARE @n1 INT, @n2 INT, @tot INT;

EXEC dbo.sp_GetStudentsWithDetails @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentsWithDetails @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Students);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentsWithDetails per school', '6 / 6 of 12',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 6 AND @n2 = 6 AND @tot = 12 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetTeachersWithDetails @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetTeachersWithDetails @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Teachers);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetTeachersWithDetails per school', '2 / 2 of 4',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 2 AND @n2 = 2 AND @tot = 4 THEN 1 ELSE 0 END);

/* sp_GetAllClasses returns the page and *then* a TotalCount row, so @@ROWCOUNT after
   EXEC is 1 however many classes came back -- the row-count probe used everywhere else
   in this section cannot be applied to it, and the '2 / 2 of 4' assertion it used to
   carry could never pass. The single-row read makes the sharper point anyway: an id
   belonging to the other school reads as absent rather than as someone else's class. */
EXEC dbo.sp_GetClassById @SchoolId = @S1, @ClassId = @C2; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetClassById @SchoolId = @S2, @ClassId = @C2; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetClassById is school-scoped', '0 / 1',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 0 AND @n2 = 1 THEN 1 ELSE 0 END);

/* Same shape for the new subject read, which defaults to including inactive rows --
   so this also says the scoping does not depend on IsActive. */
EXEC dbo.sp_GetSubjectById @SchoolId = @S1, @SubjectId = @Sub2; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetSubjectById @SchoolId = @S2, @SubjectId = @Sub2; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetSubjectById is school-scoped', '0 / 1',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 0 AND @n2 = 1 THEN 1 ELSE 0 END);

/* The two new single-school student reads. sp_GetAllStudents cannot be probed
   this way -- it ends on a TotalCount row, so @@ROWCOUNT after it is always 1 --
   and sp_GetStudentById defaults to including deactivated rows, so this also says
   the scoping does not depend on IsActive. */
EXEC dbo.sp_GetStudentById @SchoolId = @S1, @StudentId = @St2; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentById @SchoolId = @S2, @StudentId = @St2; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentById is school-scoped', '0 / 1',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 0 AND @n2 = 1 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetStudentsByClass @SchoolId = @S1, @ClassId = @C2; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentsByClass @SchoolId = @S2, @ClassId = @C2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Students
             WHERE SchoolId = @S2 AND ClassId = @C2 AND IsActive = 1);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentsByClass is school-scoped', CONCAT('0 / ', @tot),
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 0 AND @n2 = @tot THEN 1 ELSE 0 END);

EXEC dbo.sp_GetSubjects @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetSubjects @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Subjects);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetSubjects per school', '72 / 72 of 144',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 72 AND @n2 = 72 AND @tot = 144 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetFeeTypes @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetFeeTypes @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.FeeTypes);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetFeeTypes per school', '7 / 7 of 14',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 7 AND @n2 = 7 AND @tot = 14 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetAllSettings @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetAllSettings @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Settings);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetAllSettings per school', '64 / 64 of 128',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 64 AND @n2 = 64 AND @tot = 128 THEN 1 ELSE 0 END);

/* sp_GetAllUsers returns two sets now (page, then total), so @@ROWCOUNT after it
   is the count row -- always 1. sp_SearchUsers returns a single set and reads the
   same view, so it is what the per-school assertion uses. */
EXEC dbo.sp_SearchUsers @SchoolId = @S1, @PageSize = 500; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_SearchUsers @SchoolId = @S2, @PageSize = 500; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_SearchUsers per school (no SuperAdmin leak)', '9 / 9',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 9 AND @n2 = 9 THEN 1 ELSE 0 END);

/* sp_GetAllUsers itself is not asserted here: its first result set is the wide
   flat user row and its second is a single count, so INSERT ... EXEC cannot capture it and
   @@ROWCOUNT only ever reports the count row. Its paging and its TotalCount are
   covered by the API-level tests instead. The filter logic it shares with
   sp_SearchUsers is what the check above exercises.

   The compatibility view must not multiply rows. If the address OUTER APPLY ever
   loses its TOP (1), every read procedure in 04..14 starts double-counting. */
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('vw_Users returns exactly one row per Users row',
        CAST((SELECT COUNT(*) FROM dbo.Users) AS NVARCHAR(10)),
        CAST((SELECT COUNT(*) FROM dbo.vw_Users) AS NVARCHAR(10)),
        CASE WHEN (SELECT COUNT(*) FROM dbo.vw_Users) = (SELECT COUNT(*) FROM dbo.Users)
             THEN 1 ELSE 0 END);

/* Every login has a person, and the address written through the old single-string
   API reads back through vw_Users.Address unchanged. */
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Seeded teachers'' address round-trips through vw_Users',
        'Staff quarters',
        ISNULL((SELECT TOP 1 u.Address FROM dbo.vw_Users AS u
                 INNER JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
                 WHERE u.SchoolId = @S1 ORDER BY u.Id), '(none)'),
        CASE WHEN (SELECT TOP 1 u.Address FROM dbo.vw_Users AS u
                    INNER JOIN dbo.Teachers AS t ON t.SchoolId = u.SchoolId AND t.UserId = u.Id
                    WHERE u.SchoolId = @S1 ORDER BY u.Id) = N'Staff quarters'
             THEN 1 ELSE 0 END);

/* CreatedBy is the point of the audit columns: a seeded teacher must be
   attributable to the admin who registered them, not left NULL. */
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Registered users carry CreatedBy / ModifiedBy',
        '0 seeded users with a NULL CreatedBy',
        CAST((SELECT COUNT(*) FROM dbo.Users WHERE CreatedBy IS NULL) AS NVARCHAR(10)),
        CASE WHEN (SELECT COUNT(*) FROM dbo.Users WHERE CreatedBy IS NULL) = 0
             THEN 1 ELSE 0 END);

EXEC dbo.sp_GetExaminations @SchoolId = @S1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetExaminations @SchoolId = @S2; SET @n2 = @@ROWCOUNT;
SET @tot = (SELECT COUNT(*) FROM dbo.Examinations);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetExaminations per school', '4 / 4 of 8',
        CONCAT(@n1, ' / ', @n2, ' of ', @tot),
        CASE WHEN @n1 = 4 AND @n2 = 4 AND @tot = 8 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetTeacherSchedule @SchoolId = @S1, @TeacherId = @T1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetTeacherSchedule @SchoolId = @S2, @TeacherId = @T1; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetTeacherSchedule: other school sees nothing', '10 / 0',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 10 AND @n2 = 0 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetStudentFees @SchoolId = @S1, @StudentId = @St1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentFees @SchoolId = @S2, @StudentId = @St1; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentFees: other school sees nothing', '4 / 0',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 4 AND @n2 = 0 THEN 1 ELSE 0 END);

EXEC dbo.sp_GetStudentAttendance @SchoolId = @S1, @StudentId = @St1; SET @n1 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentAttendance @SchoolId = @S2, @StudentId = @St1; SET @n2 = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentAttendance: other school sees nothing', '20 / 0',
        CONCAT(@n1, ' / ', @n2),
        CASE WHEN @n1 = 20 AND @n2 = 0 THEN 1 ELSE 0 END);

/*==========================================================================
  3. DASHBOARD COUNTS ARE THIS SCHOOL'S, NOT THE INSTALLATION'S

  This is the specific bug the old sp_GetDashboardStats had.
==========================================================================*/
DECLARE @Dash TABLE (TotalStudents INT, TotalTeachers INT, TotalParents INT, TotalClasses INT,
                     TodayPresent INT, TodayAbsent INT, OverdueFees INT, TotalSubjects INT,
                     FeesOutstandingAmount DECIMAL(18,2), FeesCollectedThisMonth DECIMAL(18,2));

INSERT INTO @Dash EXEC dbo.sp_GetDashboardStats @SchoolId = @S1;

DECLARE @RawStu INT = (SELECT COUNT(*) FROM dbo.Students WHERE SchoolId = @S1 AND IsActive = 1);
DECLARE @RawOverdue INT =
    (SELECT COUNT(*) FROM dbo.Fees AS f
      LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid FROM dbo.FeePayments
                  WHERE PaymentStatus = 'Completed' GROUP BY SchoolId, FeeId) AS p
             ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
      WHERE f.SchoolId = @S1 AND f.IsActive = 1 AND f.DueDate < CAST(GETDATE() AS DATE)
        AND ISNULL(p.Paid, 0) < f.Amount);

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_GetDashboardStats matches school 1 raw truth',
       CONCAT('students=', @RawStu, ' teachers=2 classes=2 subjects=72 overdue=', @RawOverdue),
       CONCAT('students=', TotalStudents, ' teachers=', TotalTeachers, ' classes=', TotalClasses,
              ' subjects=', TotalSubjects, ' overdue=', OverdueFees),
       CASE WHEN TotalStudents = @RawStu AND TotalTeachers = 2 AND TotalClasses = 2
                 AND TotalSubjects = 72 AND OverdueFees = @RawOverdue THEN 1 ELSE 0 END
FROM @Dash;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_GetDashboardStats: money collected and money still owed',
       'collected > 0 and outstanding > 0',
       CONCAT('collected=', FeesCollectedThisMonth, ' outstanding=', FeesOutstandingAmount),
       CASE WHEN FeesCollectedThisMonth > 0 AND FeesOutstandingAmount > 0 THEN 1 ELSE 0 END
FROM @Dash;

/*==========================================================================
  4. THE SAME CLASS NAME IN TWO SCHOOLS

  Both schools have a class called 10-A. Registering the same person, with the
  same email, into both must succeed with distinct identifiers. On the old
  single-school schema this failed on the global UNIQUE constraints.
==========================================================================*/
/* ClassName is the seventh column sp_RegisterStudent returns now. INSERT ... EXEC
   matches by position and count, so a missing column here fails the whole batch
   rather than the assertion -- which is the useful direction. */
DECLARE @Reg TABLE (SchoolId INT, Result NVARCHAR(500), UserId INT, StudentRecordId INT,
                    Username NVARCHAR(80), StudentId NVARCHAR(40), RollNumber NVARCHAR(10),
                    ClassName NVARCHAR(50));
DECLARE @One TABLE (Result NVARCHAR(500), UserId INT, StudentRecordId INT,
                    Username NVARCHAR(80), StudentId NVARCHAR(40), RollNumber NVARCHAR(10),
                    ClassName NVARCHAR(50));

DECLARE @Cls1 INT = (SELECT Id FROM dbo.Classes WHERE SchoolId = @S1 AND ClassName = N'10-A');
DECLARE @Cls2 INT = (SELECT Id FROM dbo.Classes WHERE SchoolId = @S2 AND ClassName = N'10-A');

INSERT INTO @One EXEC dbo.sp_RegisterStudent @SchoolId = @S1, @FirstName = N'Same',
       @LastName = N'Name', @Email = N'same.name@dup.test', @ClassId = @Cls1;
INSERT INTO @Reg SELECT @S1, * FROM @One; DELETE FROM @One;

INSERT INTO @One EXEC dbo.sp_RegisterStudent @SchoolId = @S2, @FirstName = N'Same',
       @LastName = N'Name', @Email = N'same.name@dup.test', @ClassId = @Cls2;
INSERT INTO @Reg SELECT @S2, * FROM @One; DELETE FROM @One;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Same name, same email, same class name in both schools',
       '2 successes, distinct usernames and student ids',
       (SELECT STRING_AGG(CONCAT(Result, ' ', Username, ' ', StudentId, ' roll ', RollNumber,
                                 ' in ', ISNULL(ClassName, N'(no class returned)')), ' | ')
          FROM @Reg),
       CASE WHEN (SELECT COUNT(*) FROM @Reg WHERE Result = 'Success') = 2
             AND (SELECT COUNT(DISTINCT Username) FROM @Reg) = 2
             AND (SELECT COUNT(DISTINCT StudentId) FROM @Reg) = 2
             /* ClassName feeds the confirmation the admin reads after
                registering, so an empty one is a failure here. */
             AND NOT EXISTS (SELECT 1 FROM @Reg WHERE Result = 'Success' AND ClassName IS NULL)
            THEN 1 ELSE 0 END;

/*==========================================================================
  5. ROLL NUMBERS COME FROM A SEQUENCE, NOT COUNT(*) + 1

  Sequential here. For the actual race, run the same registration loop from two
  sessions at once and confirm the roll numbers are still all distinct.
==========================================================================*/
DECLARE @Rolls TABLE (RollNumber NVARCHAR(10));
DECLARE @k INT = 1, @Last NVARCHAR(50), @Mail NVARCHAR(100);
WHILE @k <= 4
BEGIN
    DELETE FROM @One;
    SET @Last = CONCAT(N'Test', @k);
    SET @Mail = CONCAT(N'seq.test', @k, N'@roll.test');
    INSERT INTO @One EXEC dbo.sp_RegisterStudent @SchoolId = @S1, @FirstName = N'Seq',
           @LastName = @Last, @Email = @Mail, @ClassId = @Cls1;
    INSERT INTO @Rolls SELECT RollNumber FROM @One WHERE Result = 'Success';
    SET @k += 1;
END

INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Four registrations got four distinct roll numbers', '4',
        CAST((SELECT COUNT(DISTINCT RollNumber) FROM @Rolls) AS NVARCHAR(10)),
        CASE WHEN (SELECT COUNT(DISTINCT RollNumber) FROM @Rolls) = 4 THEN 1 ELSE 0 END);

/* Deleting a student must not let the next registration reuse their number. */
DECLARE @DelRoll NVARCHAR(10) = (SELECT MAX(RollNumber) FROM @Rolls);
DELETE FROM dbo.Attendance WHERE SchoolId = @S1 AND StudentId IN
       (SELECT Id FROM dbo.Students WHERE SchoolId = @S1 AND RollNumber = @DelRoll);
DELETE FROM dbo.StudentSubjects WHERE SchoolId = @S1 AND StudentId IN
       (SELECT Id FROM dbo.Students WHERE SchoolId = @S1 AND RollNumber = @DelRoll);
DELETE FROM dbo.Fees WHERE SchoolId = @S1 AND StudentId IN
       (SELECT Id FROM dbo.Students WHERE SchoolId = @S1 AND RollNumber = @DelRoll);
DELETE FROM dbo.Students WHERE SchoolId = @S1 AND RollNumber = @DelRoll;

DELETE FROM @One;
INSERT INTO @One EXEC dbo.sp_RegisterStudent @SchoolId = @S1, @FirstName = N'Seq',
       @LastName = N'AfterDelete', @Email = N'seq.afterdelete@roll.test', @ClassId = @Cls1;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Roll numbers are never reused after a delete',
       CONCAT('not ', @DelRoll),
       (SELECT RollNumber FROM @One),
       CASE WHEN (SELECT RollNumber FROM @One) <> @DelRoll THEN 1 ELSE 0 END;

/*==========================================================================
  6. THE FEATURES THAT WERE BROKEN BEFORE
==========================================================================*/
DECLARE @SubIds NVARCHAR(MAX) =
    (SELECT STRING_AGG(CAST(Id AS NVARCHAR(10)), ',')
       FROM (SELECT TOP 3 Id FROM dbo.Subjects WHERE SchoolId = @S1 AND Grade = N'10'
              ORDER BY Id) AS x);
DECLARE @TargetStudent INT = (SELECT TOP 1 Id FROM dbo.Students WHERE SchoolId = @S1 ORDER BY Id);
DECLARE @TargetUser INT = (SELECT UserId FROM dbo.Students WHERE SchoolId = @S1 AND Id = @TargetStudent);

DECLARE @Assign TABLE (Result NVARCHAR(500), Message NVARCHAR(500), SubjectsAssigned INT);
INSERT INTO @Assign EXEC dbo.sp_AssignSubjectsToStudent @SchoolId = @S1,
       @StudentId = @TargetStudent, @SubjectIds = @SubIds, @ReplaceExisting = 1;

DECLARE @StatSubjects INT =
    (SELECT COUNT(*) FROM dbo.StudentSubjects
      WHERE SchoolId = @S1 AND StudentId = @TargetStudent AND IsActive = 1);

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_AssignSubjectsToStudent writes rows (used to be a no-op)',
       '3 rows in StudentSubjects',
       CONCAT((SELECT Result FROM @Assign), ', rows=', @StatSubjects),
       CASE WHEN @StatSubjects = 3 THEN 1 ELSE 0 END;

/* sp_RemoveStudentSubject, run twice: the second call is the double-click, and
   "already unassigned" is success, not an error the user cannot act on. */
DECLARE @DropSubject INT = (SELECT TOP 1 SubjectId FROM dbo.StudentSubjects
                             WHERE SchoolId = @S1 AND StudentId = @TargetStudent AND IsActive = 1
                             ORDER BY SubjectId);
DECLARE @Drop TABLE (Seq INT IDENTITY(1,1), Result NVARCHAR(500));
INSERT INTO @Drop (Result) EXEC dbo.sp_RemoveStudentSubject @SchoolId = @S1,
       @StudentId = @TargetStudent, @SubjectId = @DropSubject;
INSERT INTO @Drop (Result) EXEC dbo.sp_RemoveStudentSubject @SchoolId = @S1,
       @StudentId = @TargetStudent, @SubjectId = @DropSubject;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_RemoveStudentSubject unassigns, and is idempotent',
       'Success | Success, 2 left',
       CONCAT((SELECT STRING_AGG(Result, ' | ') FROM @Drop), ', ',
              (SELECT COUNT(*) FROM dbo.StudentSubjects
                WHERE SchoolId = @S1 AND StudentId = @TargetStudent AND IsActive = 1), ' left'),
       CASE WHEN (SELECT COUNT(*) FROM @Drop WHERE Result = 'Success') = 2
             AND (SELECT COUNT(*) FROM dbo.StudentSubjects
                   WHERE SchoolId = @S1 AND StudentId = @TargetStudent AND IsActive = 1) = 2
            THEN 1 ELSE 0 END;

DELETE FROM @Drop;
INSERT INTO @Drop (Result) EXEC dbo.sp_RemoveStudentSubject @SchoolId = @S2,
       @StudentId = @TargetStudent, @SubjectId = @DropSubject;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_RemoveStudentSubject refuses another school''s student',
        'Error: Student not found in this school',
        (SELECT TOP 1 Result FROM @Drop),
        CASE WHEN (SELECT TOP 1 Result FROM @Drop) = 'Error: Student not found in this school'
             THEN 1 ELSE 0 END);

/* sp_PromoteStudent: the class moves, the roll number is reallocated from the
   target class's own counter, and subject enrolments from the old grade are
   dropped rather than following the student up a year. */
DECLARE @CurrentClass INT = (SELECT ClassId FROM dbo.Students
                              WHERE SchoolId = @S1 AND Id = @TargetStudent);
DECLARE @PromoteTo INT = (SELECT TOP 1 c.Id
                            FROM dbo.Classes AS c
                           WHERE c.SchoolId = @S1
                             AND c.IsActive = 1
                             AND c.Id <> ISNULL(@CurrentClass, 0)
                             AND (SELECT COUNT(*) FROM dbo.Students AS s
                                   WHERE s.SchoolId = @S1 AND s.ClassId = c.Id AND s.IsActive = 1)
                                 < c.MaxStudents
                           ORDER BY c.Id);
DECLARE @NewGrade NVARCHAR(10) = (SELECT Grade FROM dbo.Classes
                                   WHERE SchoolId = @S1 AND Id = @PromoteTo);

DECLARE @Promo TABLE (Result NVARCHAR(500));
INSERT INTO @Promo EXEC dbo.sp_PromoteStudent @SchoolId = @S1, @StudentId = @TargetStudent,
       @NewClassId = @PromoteTo, @AcademicYear = 2026, @PerformedByUserId = @U1;

DECLARE @NowClass INT, @NowRoll NVARCHAR(10);
SELECT @NowClass = ClassId, @NowRoll = RollNumber
FROM dbo.Students WHERE SchoolId = @S1 AND Id = @TargetStudent;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_PromoteStudent moves the class and reallocates the roll number',
       'Success, in the target class, roll unique there',
       CONCAT((SELECT TOP 1 Result FROM @Promo), ', class=', @NowClass, ', roll=', @NowRoll),
       CASE WHEN (SELECT TOP 1 Result FROM @Promo) = 'Success'
             AND @NowClass = @PromoteTo
             AND @NowRoll IS NOT NULL
             AND (SELECT COUNT(*) FROM dbo.Students
                   WHERE SchoolId = @S1 AND ClassId = @PromoteTo AND RollNumber = @NowRoll) = 1
            THEN 1 ELSE 0 END;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Promotion drops subject enrolments from the old grade',
       CONCAT('0 subjects outside grade ', @NewGrade),
       CAST((SELECT COUNT(*)
               FROM dbo.StudentSubjects AS ss
               INNER JOIN dbo.Subjects AS sub
                       ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
              WHERE ss.SchoolId = @S1 AND ss.StudentId = @TargetStudent
                AND ss.IsActive = 1 AND sub.Grade <> @NewGrade) AS NVARCHAR(10)),
       CASE WHEN (SELECT COUNT(*)
                    FROM dbo.StudentSubjects AS ss
                    INNER JOIN dbo.Subjects AS sub
                            ON sub.SchoolId = ss.SchoolId AND sub.Id = ss.SubjectId
                   WHERE ss.SchoolId = @S1 AND ss.StudentId = @TargetStudent
                     AND ss.IsActive = 1 AND sub.Grade <> @NewGrade) = 0
            THEN 1 ELSE 0 END;

DELETE FROM @Promo;
INSERT INTO @Promo EXEC dbo.sp_PromoteStudent @SchoolId = @S1, @StudentId = @TargetStudent,
       @NewClassId = @PromoteTo, @AcademicYear = 2026, @PerformedByUserId = @U1;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Promoting into the class the student is already in is refused',
        'Error: Student is already in ...',
        (SELECT TOP 1 Result FROM @Promo),
        CASE WHEN (SELECT TOP 1 Result FROM @Promo) LIKE 'Error: Student is already in %'
             THEN 1 ELSE 0 END);

/* sp_GetStudentProfile declared @UserId only, while the repository calls it with
   @StudentId -- so every profile request failed on the parameter name before it
   reached any data. It now accepts either. */
DECLARE @ProfParams INT = (SELECT COUNT(*) FROM sys.parameters
                            WHERE object_id = OBJECT_ID(N'dbo.sp_GetStudentProfile')
                              AND name IN (N'@StudentId', N'@UserId'));
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentProfile takes @StudentId and @UserId', '2 parameters',
        CONCAT(@ProfParams, ' parameters'),
        CASE WHEN @ProfParams = 2 THEN 1 ELSE 0 END);

DECLARE @n3 INT, @n4 INT;
EXEC dbo.sp_GetStudentProfile @SchoolId = @S1, @StudentId = @TargetStudent;
SET @n3 = @@ROWCOUNT;
EXEC dbo.sp_GetStudentProfile @SchoolId = @S1, @UserId = @TargetUser;
SET @n4 = @@ROWCOUNT;
/* @@ROWCOUNT is the fee-status set, the procedure's last statement, so this says
   both keys run to completion -- not that every set is populated. The four sets
   the repository reads are covered by the API, which is what consumes them. */
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetStudentProfile runs under both keys', '1 / 1', CONCAT(@n3, ' / ', @n4),
        CASE WHEN @n3 = 1 AND @n4 = 1 THEN 1 ELSE 0 END);

DECLARE @Pic TABLE (Result NVARCHAR(500));
DECLARE @Bytes VARBINARY(MAX) = CAST(N'PNGDATA-ROUNDTRIP' AS VARBINARY(MAX));
INSERT INTO @Pic EXEC dbo.sp_UpdateProfilePicture @SchoolId = @S1, @UserId = @TargetUser,
       @ProfilePicture = @Bytes, @FileName = N'me.png', @ContentType = N'image/png';

DECLARE @PicOut TABLE (ProfilePicture VARBINARY(MAX), ProfilePictureFileName NVARCHAR(255),
                       ProfilePictureContentType NVARCHAR(100), ProfilePictureUploadDate DATETIME);
INSERT INTO @PicOut EXEC dbo.sp_GetProfilePicture @SchoolId = @S1, @UserId = @TargetUser;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Profile picture round-trips (its columns never existed)',
       'same bytes back, me.png',
       CONCAT(CAST(ProfilePicture AS NVARCHAR(40)), ', ', ProfilePictureFileName),
       CASE WHEN ProfilePicture = @Bytes AND ProfilePictureFileName = N'me.png' THEN 1 ELSE 0 END
FROM @PicOut;

DELETE FROM @PicOut;
INSERT INTO @PicOut EXEC dbo.sp_GetProfilePicture @SchoolId = @S2, @UserId = @TargetUser;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Profile picture is not readable from the other school', '0 rows',
        CAST((SELECT COUNT(*) FROM @PicOut) AS NVARCHAR(10)),
        CASE WHEN (SELECT COUNT(*) FROM @PicOut) = 0 THEN 1 ELSE 0 END);

/*==========================================================================
  7. A BRAND NEW SCHOOL IS USABLE THE MOMENT IT IS CREATED
==========================================================================*/
DECLARE @NewRes TABLE (Result NVARCHAR(500), SchoolId INT, SchoolCode NVARCHAR(12),
                       AdminUserId INT, AdminUsername NVARCHAR(80));
DECLARE @Super INT = (SELECT Id FROM dbo.Users WHERE Username = N'superadmin');

INSERT INTO @NewRes EXEC dbo.sp_CreateSchool
       @SchoolCode = N'VERIFY1', @SchoolName = N'Verification Academy',
       @AdminEmail = N'admin@verify1.test',
       @AdminPasswordHash = N'$2a$11$5h2hU20MWEt31LzKAz9zoOn5aPVypsE63IQw5BvfLTTD.q/lxA/wa',
       @CreatedByUserId = @Super;

DECLARE @NewId INT = (SELECT SchoolId FROM @NewRes);
DECLARE @NewAdmin NVARCHAR(80) = (SELECT AdminUsername FROM @NewRes);

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_CreateSchool leaves the new school ready to use',
       'subjects=72 feetypes=7 settings=64 sequences=3 admins=1',
       CONCAT('subjects=', (SELECT COUNT(*) FROM dbo.Subjects WHERE SchoolId = @NewId),
              ' feetypes=', (SELECT COUNT(*) FROM dbo.FeeTypes WHERE SchoolId = @NewId),
              ' settings=', (SELECT COUNT(*) FROM dbo.Settings WHERE SchoolId = @NewId),
              ' sequences=', (SELECT COUNT(*) FROM dbo.SchoolSequences WHERE SchoolId = @NewId),
              ' admins=', (SELECT COUNT(*) FROM dbo.Users WHERE SchoolId = @NewId AND RoleId = 2)),
       CASE WHEN (SELECT COUNT(*) FROM dbo.Subjects WHERE SchoolId = @NewId) = 72
             AND (SELECT COUNT(*) FROM dbo.FeeTypes WHERE SchoolId = @NewId) = 7
             AND (SELECT COUNT(*) FROM dbo.Settings WHERE SchoolId = @NewId) = 64
             AND (SELECT COUNT(*) FROM dbo.SchoolSequences WHERE SchoolId = @NewId) = 3
             AND (SELECT COUNT(*) FROM dbo.Users WHERE SchoolId = @NewId AND RoleId = 2) = 1
            THEN 1 ELSE 0 END;

/* sp_Login returns two sets now -- the user row, then the permission grid -- so
   @@ROWCOUNT after it is the size of the grid. Both sets carry the same
   eligibility filter, so "grid is empty" and "login refused" are the same
   statement, which is what these two checks lean on. */
DECLARE @LoginRows INT;
DECLARE @AdminModules INT = (SELECT COUNT(*) FROM dbo.RolePermissions
                              WHERE RoleId = 2 AND IsActive = 1);

EXEC dbo.sp_Login @Username = @NewAdmin; SET @LoginRows = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('The new school''s admin resolves through sp_Login (with a permission grid)',
        CONCAT(@AdminModules, ' permission rows'),
        CAST(@LoginRows AS NVARCHAR(10)),
        CASE WHEN @LoginRows = @AdminModules AND @AdminModules > 0 THEN 1 ELSE 0 END);

EXEC dbo.sp_ToggleSchoolStatus @SchoolId = @NewId, @IsActive = 0;
EXEC dbo.sp_Login @Username = @NewAdmin; SET @LoginRows = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Login is refused while the school is deactivated (neither set returned)',
        '0 rows',
        CAST(@LoginRows AS NVARCHAR(10)),
        CASE WHEN @LoginRows = 0 THEN 1 ELSE 0 END);

EXEC dbo.sp_ToggleSchoolStatus @SchoolId = @NewId, @IsActive = 1;

/* The SuperAdmin has no school at all, so the RoleId = 1 escape in that filter is
   the only thing that lets them in. If it is ever "simplified" away, the platform
   operator is locked out of their own installation. */
EXEC dbo.sp_Login @Username = N'superadmin'; SET @LoginRows = @@ROWCOUNT;
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('SuperAdmin (SchoolId NULL) still resolves through sp_Login',
        'more than 0 permission rows',
        CAST(@LoginRows AS NVARCHAR(10)),
        CASE WHEN @LoginRows > 0 THEN 1 ELSE 0 END);

/*==========================================================================
  7b. ROLES AND PERMISSIONS
==========================================================================*/
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Five system roles are seeded by the schema, not the seed script', '5',
        CAST((SELECT COUNT(*) FROM dbo.Roles WHERE IsSystemRole = 1) AS NVARCHAR(10)),
        CASE WHEN (SELECT COUNT(*) FROM dbo.Roles WHERE IsSystemRole = 1) = 5
             THEN 1 ELSE 0 END);

INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Role ids match the Constants.RoleIds contract',
        '1=SuperAdmin 2=Admin 3=Teacher 4=Student 5=Parent',
        CONCAT('1=', dbo.fn_RoleName(1), ' 2=', dbo.fn_RoleName(2), ' 3=', dbo.fn_RoleName(3),
               ' 4=', dbo.fn_RoleName(4), ' 5=', dbo.fn_RoleName(5)),
        CASE WHEN dbo.fn_RoleName(1) = N'SuperAdmin' AND dbo.fn_RoleName(2) = N'Admin'
              AND dbo.fn_RoleName(3) = N'Teacher'    AND dbo.fn_RoleName(4) = N'Student'
              AND dbo.fn_RoleName(5) = N'Parent'     THEN 1 ELSE 0 END);

INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('fn_RoleId resolves a role by name and by code', '2 / 2',
        CONCAT(dbo.fn_RoleId(N'Admin'), ' / ', dbo.fn_RoleId(N'ADMIN')),
        CASE WHEN dbo.fn_RoleId(N'Admin') = 2 AND dbo.fn_RoleId(N'ADMIN') = 2
             THEN 1 ELSE 0 END);

/* A custom role must be given an id at 100 or above and must be deletable, since
   nothing in the schema hard-codes it. */
DECLARE @NewRole TABLE (Result NVARCHAR(500), RoleId INT);
INSERT INTO @NewRole EXEC dbo.sp_CreateRole @RoleName = N'Librarian',
       @RoleCode = N'LIBRARIAN', @Description = N'Runs the library', @CreatedBy = @Super;

DECLARE @CustomRoleId INT = (SELECT RoleId FROM @NewRole);
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_CreateRole allocates a custom role at 100+', 'Success, id >= 100',
        CONCAT((SELECT Result FROM @NewRole), ', id=', ISNULL(CAST(@CustomRoleId AS NVARCHAR(10)), 'NULL')),
        CASE WHEN @CustomRoleId >= 100 THEN 1 ELSE 0 END);

/* CanDelete without CanView must be corrected to CanView = 1 rather than
   rejected: the permissions screen sends the four flags as ticked, and failing
   the whole save on an implied flag is a worse experience than granting it. */
DECLARE @PermSave TABLE (Result NVARCHAR(500));
INSERT INTO @PermSave EXEC dbo.sp_SaveRolePermission @RoleId = @CustomRoleId,
       @ModuleName = N'Students', @CanView = 0, @CanCreate = 0, @CanEdit = 1,
       @CanDelete = 0, @ModifiedBy = @Super;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_SaveRolePermission implies CanView when edit is granted',
       'CanView = 1',
       CONCAT('CanView=', CanView, ' CanEdit=', CanEdit),
       CASE WHEN CanView = 1 AND CanEdit = 1 THEN 1 ELSE 0 END
FROM dbo.RolePermissions
WHERE RoleId = @CustomRoleId AND ModuleName = N'Students';

/* A system role cannot be renamed or removed: the authorization attributes in C#
   are compiled against its name. */
DECLARE @RoleUpd TABLE (Result NVARCHAR(500));
INSERT INTO @RoleUpd EXEC dbo.sp_UpdateRole @RoleId = 2, @RoleName = N'Renamed',
       @ModifiedBy = @Super;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'A system role cannot be renamed', 'Error, still called Admin',
       CONCAT((SELECT TOP 1 Result FROM @RoleUpd), ' -> ', dbo.fn_RoleName(2)),
       CASE WHEN dbo.fn_RoleName(2) = N'Admin' THEN 1 ELSE 0 END;

DELETE FROM @RoleUpd;
INSERT INTO @RoleUpd EXEC dbo.sp_DeleteRole @RoleId = 2;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'A system role cannot be deleted', 'Error, role 2 still present',
       CONCAT((SELECT TOP 1 Result FROM @RoleUpd), ' -> ',
              CAST((SELECT COUNT(*) FROM dbo.Roles WHERE Id = 2) AS NVARCHAR(10))),
       CASE WHEN (SELECT COUNT(*) FROM dbo.Roles WHERE Id = 2) = 1 THEN 1 ELSE 0 END;

/* Every user's effective grid comes from their role. A Student must not have
   delete on Users -- if this ever passes, the permission seed has been widened. */
DECLARE @StuUser INT = (SELECT TOP 1 UserId FROM dbo.Students WHERE SchoolId = @S1 ORDER BY Id);
DECLARE @Grid TABLE (ModuleName NVARCHAR(50), CanView BIT, CanCreate BIT, CanEdit BIT, CanDelete BIT);
INSERT INTO @Grid EXEC dbo.sp_GetUserPermissions @UserId = @StuUser;

INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('sp_GetUserPermissions gives a student read-only access',
        'no create/edit/delete anywhere',
        CONCAT('modules=', (SELECT COUNT(*) FROM @Grid),
               ' writable=', (SELECT COUNT(*) FROM @Grid
                               WHERE CanCreate = 1 OR CanEdit = 1 OR CanDelete = 1)),
        CASE WHEN (SELECT COUNT(*) FROM @Grid) > 0
              AND (SELECT COUNT(*) FROM @Grid
                    WHERE CanCreate = 1 OR CanEdit = 1 OR CanDelete = 1) = 0
             THEN 1 ELSE 0 END);

/* Users cannot be moved between the role-specific tables by a role change:
   a Student row is keyed on UserId and would be orphaned. */
DECLARE @RoleChg TABLE (Result NVARCHAR(500));
INSERT INTO @RoleChg EXEC dbo.sp_ChangeUserRole @SchoolId = @S1, @UserId = @StuUser,
       @RoleId = 2, @ModifiedBy = @U1;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_ChangeUserRole refuses to move a student out of role 4',
       'Error, still RoleId 4',
       CONCAT((SELECT TOP 1 Result FROM @RoleChg), ' -> RoleId ',
              (SELECT RoleId FROM dbo.Users WHERE Id = @StuUser)),
       CASE WHEN (SELECT RoleId FROM dbo.Users WHERE Id = @StuUser) = 4 THEN 1 ELSE 0 END;

/* Deleting the picture must clear the metadata with it, not leave a filename
   pointing at bytes that are gone. */
DELETE FROM @Pic;
INSERT INTO @Pic EXEC dbo.sp_DeleteProfilePicture @SchoolId = @S1, @UserId = @TargetUser;
DELETE FROM @PicOut;
INSERT INTO @PicOut EXEC dbo.sp_GetProfilePicture @SchoolId = @S1, @UserId = @TargetUser;

INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'sp_DeleteProfilePicture clears the bytes and the metadata',
       'all four columns NULL',
       CONCAT('bytes=', CASE WHEN ProfilePicture IS NULL THEN 'NULL' ELSE 'present' END,
              ' name=', ISNULL(ProfilePictureFileName, 'NULL'),
              ' type=', ISNULL(ProfilePictureContentType, 'NULL')),
       CASE WHEN ProfilePicture IS NULL AND ProfilePictureFileName IS NULL
             AND ProfilePictureContentType IS NULL AND ProfilePictureUploadDate IS NULL
            THEN 1 ELSE 0 END
FROM @PicOut;

/* The grading scale must come from the school's own settings, not a hardcoded
   scale shared by everyone. */
DECLARE @S2Admin INT = (SELECT TOP 1 Id FROM dbo.Users WHERE SchoolId = @S2 AND RoleId = 2);
EXEC dbo.sp_SaveSetting @SchoolId = @S2, @Category = N'AcademicSettings',
     @SettingKey = N'gradeThresholdAPlus', @SettingValue = N'50', @DataType = N'number',
     @UserId = @S2Admin;

INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('fn_CalculateGrade reads each school''s own thresholds',
        'school 2 grades 55% as A+, school 1 does not',
        CONCAT('school1=', dbo.fn_CalculateGrade(@S1, 55, 100),
               ' school2=', dbo.fn_CalculateGrade(@S2, 55, 100)),
        CASE WHEN dbo.fn_CalculateGrade(@S2, 55, 100) = 'A+'
              AND dbo.fn_CalculateGrade(@S1, 55, 100) <> 'A+' THEN 1 ELSE 0 END);

/*==========================================================================
  PHASE 13: SCHEDULE WRITES

  A clash names the lesson in the way; the subject must match the class's
  grade; a blank room is no room; a deleted entry cannot be edited back to life.
==========================================================================*/
DECLARE @SchedOut TABLE (Result NVARCHAR(20), Message NVARCHAR(400), Id INT, ConflictWith INT);
DECLARE @L1 INT, @LT INT, @LS INT, @LC INT, @LD INT, @LStart TIME(0), @LEnd TIME(0);
SELECT TOP 1 @L1 = Id, @LT = TeacherId, @LS = SubjectId, @LC = ClassId, @LD = DayOfWeek,
             @LStart = StartTime, @LEnd = EndTime
FROM dbo.TeacherSchedule WHERE SchoolId = @S1 AND IsActive = 1 ORDER BY Id;

/* The same slot again: the teacher is busy, and it is that lesson. */
INSERT INTO @SchedOut EXEC dbo.sp_CreateOrUpdateScheduleEntry @SchoolId = @S1,
       @TeacherId = @LT, @SubjectId = @LS, @ClassId = @LC, @DayOfWeek = @LD,
       @StartTime = @LStart, @EndTime = @LEnd;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Schedule clash: Conflict naming the other entry', CONCAT('Conflict / ', @L1),
       CONCAT(Result, ' / ', ConflictWith, ' / ', Message),
       CASE WHEN Result = 'Conflict' AND ConflictWith = @L1 THEN 1 ELSE 0 END
FROM @SchedOut;
DELETE FROM @SchedOut;

/* A subject from another grade than the class. */
DECLARE @OtherGradeSubject INT = (
    SELECT TOP 1 s.Id FROM dbo.Subjects AS s
    WHERE s.SchoolId = @S1 AND s.IsActive = 1
      AND s.Grade <> (SELECT Grade FROM dbo.Classes WHERE Id = @LC));
INSERT INTO @SchedOut EXEC dbo.sp_CreateOrUpdateScheduleEntry @SchoolId = @S1,
       @TeacherId = @LT, @SubjectId = @OtherGradeSubject, @ClassId = @LC, @DayOfWeek = 7,
       @StartTime = '23:00', @EndTime = '23:30';
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Schedule: subject must be in the class''s grade', 'Error, "is a grade"',
       CONCAT(Result, ' / ', Message),
       CASE WHEN Result = 'Error' AND Message LIKE N'%is a grade%' THEN 1 ELSE 0 END
FROM @SchedOut;
DELETE FROM @SchedOut;

/* A room of spaces is stored as no room. Sunday 23:00 is free in the seed. */
INSERT INTO @SchedOut EXEC dbo.sp_CreateOrUpdateScheduleEntry @SchoolId = @S1,
       @TeacherId = @LT, @SubjectId = @LS, @ClassId = @LC, @DayOfWeek = 7,
       @StartTime = '23:00', @EndTime = '23:30', @Room = N'   ';
DECLARE @Blank INT = (SELECT Id FROM @SchedOut WHERE Result = 'Success');
INSERT INTO @R (Chk, Expected, Actual, Pass)
VALUES ('Schedule: blank room stored as NULL', 'Success, Room NULL',
        CONCAT((SELECT TOP 1 Result FROM @SchedOut), ', Room ',
               ISNULL((SELECT QUOTENAME(Room, '''') FROM dbo.TeacherSchedule WHERE Id = @Blank), 'NULL')),
        CASE WHEN @Blank IS NOT NULL
              AND EXISTS (SELECT 1 FROM dbo.TeacherSchedule WHERE Id = @Blank AND Room IS NULL)
             THEN 1 ELSE 0 END);
DELETE FROM @SchedOut;

/* Deleted, then "edited": refused, and it stays deleted. */
DECLARE @DelOut TABLE (Result NVARCHAR(20), Message NVARCHAR(400));
INSERT INTO @DelOut EXEC dbo.sp_DeleteScheduleEntry @SchoolId = @S1, @Id = @Blank;
INSERT INTO @SchedOut EXEC dbo.sp_CreateOrUpdateScheduleEntry @SchoolId = @S1, @Id = @Blank,
       @TeacherId = @LT, @SubjectId = @LS, @ClassId = @LC, @DayOfWeek = 7,
       @StartTime = '23:00', @EndTime = '23:30';
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Schedule: editing a deleted entry is refused', 'Error, still inactive',
       CONCAT(Result, ' / ', Message, ' / IsActive=',
              (SELECT IsActive FROM dbo.TeacherSchedule WHERE Id = @Blank)),
       CASE WHEN Result = 'Error' AND Message LIKE N'Schedule entry not found%'
             AND EXISTS (SELECT 1 FROM dbo.TeacherSchedule WHERE Id = @Blank AND IsActive = 0)
            THEN 1 ELSE 0 END
FROM @SchedOut;
DELETE FROM @SchedOut;

/*==========================================================================
  PHASE 14: ROLES

  A system role's description is editable even though its name is resent;
  the SuperAdmin grid is not writable; ModuleCount counts what a role sees.
==========================================================================*/
DELETE FROM @RoleUpd;
INSERT INTO @RoleUpd EXEC dbo.sp_UpdateRole @RoleId = 2, @RoleName = N'Admin',
       @Description = N'Runs one school', @IsActive = 1, @ModifiedBy = @Super;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Roles: system role description edit with its own name', 'Success, description saved',
       CONCAT((SELECT TOP 1 Result FROM @RoleUpd), ' / ',
              (SELECT Description FROM dbo.Roles WHERE Id = 2)),
       CASE WHEN (SELECT TOP 1 Result FROM @RoleUpd) = 'Success'
             AND (SELECT Description FROM dbo.Roles WHERE Id = 2) = N'Runs one school'
            THEN 1 ELSE 0 END;

DELETE FROM @PermSave;
INSERT INTO @PermSave EXEC dbo.sp_SaveRolePermission @RoleId = 1,
       @ModuleName = N'Users', @CanView = 0, @ModifiedBy = @Super;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Roles: SuperAdmin grid cannot be changed', 'Error, Users still VCED',
       CONCAT((SELECT TOP 1 Result FROM @PermSave), ' / CanView=',
              (SELECT CanView FROM dbo.RolePermissions WHERE RoleId = 1 AND ModuleName = N'Users')),
       CASE WHEN (SELECT TOP 1 Result FROM @PermSave) LIKE 'Error:%'
             AND EXISTS (SELECT 1 FROM dbo.RolePermissions
                         WHERE RoleId = 1 AND ModuleName = N'Users' AND CanView = 1 AND CanDelete = 1)
            THEN 1 ELSE 0 END;

/* An all-off row is written when a module is switched off; it grants nothing
   and must not count. The Librarian holds Students (edit) from above. */
DELETE FROM @PermSave;
INSERT INTO @PermSave EXEC dbo.sp_SaveRolePermission @RoleId = @CustomRoleId,
       @ModuleName = N'Fees', @ModifiedBy = @Super;
DECLARE @Roles TABLE (Id INT, RoleName NVARCHAR(50), RoleCode NVARCHAR(20), Description NVARCHAR(255),
                      IsSystemRole BIT, IsActive BIT, UserCount INT, ModuleCount INT,
                      CreatedBy INT, CreatedByUsername NVARCHAR(100), ModifiedBy INT,
                      ModifiedByUsername NVARCHAR(100), CreatedAt DATETIME, UpdatedAt DATETIME);
INSERT INTO @Roles EXEC dbo.sp_GetRoles;
INSERT INTO @R (Chk, Expected, Actual, Pass)
SELECT 'Roles: ModuleCount ignores an all-off row', '1', CAST(ModuleCount AS NVARCHAR(10)),
       CASE WHEN ModuleCount = 1 THEN 1 ELSE 0 END
FROM @Roles WHERE Id = @CustomRoleId;

/*==========================================================================
  REPORT
==========================================================================*/
SELECT CASE WHEN Pass = 1 THEN 'PASS' ELSE '**FAIL**' END AS Status,
       Chk, Expected, Actual
FROM @R
ORDER BY Ord;

DECLARE @Total INT = (SELECT COUNT(*) FROM @R);
DECLARE @Ok INT = (SELECT COUNT(*) FROM @R WHERE Pass = 1);
PRINT CONCAT('VERIFY SUMMARY: ', @Ok, ' / ', @Total, ' passed.');
PRINT 'This database now holds test data. Rebuild from 00_Drop_All.sql before using it.';
GO
