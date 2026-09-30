/*==============================================================================
  15_Seed.sql  --  Development seed data.

  Creates:
    * one SuperAdmin (SchoolId NULL) who can create further schools
    * two schools, DPSNOIDA and STMARY, each with its own admin, classes,
      teachers, students, timetable, attendance, exam results and fees

  Two schools rather than one on purpose: cross-school isolation cannot be
  tested with a single tenant, and every read procedure should return disjoint
  rows for @SchoolId = 1 and @SchoolId = 2.

  Roles and RolePermissions are NOT seeded here -- they are system reference data
  and 01_Schema.sql creates them, because CK_Users_SchoolScope names RoleId 1 and
  the schema is not self-consistent without those five rows. Persons and
  Addresses are never inserted directly either: sp_CreateUserAccount (via
  sp_CreateSchool / sp_RegisterTeacher / sp_RegisterStudent) writes the
  user/person/address trio together, which is also what stamps CreatedBy and
  ModifiedBy so the audit trail in this database is real rather than all NULL.

  Everything that generates an identifier goes through its procedure --
  sp_CreateSchool, sp_CreateClass, sp_RegisterTeacher, sp_RegisterStudent,
  sp_MakeFeePayment -- so usernames, admission numbers, employee ids, roll
  numbers and receipt numbers come from SchoolSequences exactly as they will in
  production, and the seed doubles as a smoke test of those paths. Bulk rows with
  no generated identity (subject links, timetable, attendance, results, fee
  rows) are inserted set-based: it is faster and keeps the script's output
  readable instead of emitting a result set per row.

  DEV PASSWORDS -- change these before this database is reachable by anyone else:
    superadmin              / admin123
    DPSNOIDA_ADMIN          / admin123
    STMARY_ADMIN            / admin123
    every teacher / student  / Temp@123   (RequirePasswordChange = 1)

  Re-running is a no-op: if DPSNOIDA already exists the script reports that and
  stops rather than double-registering everybody. Use 00_Drop_All.sql for a
  clean slate.
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

IF EXISTS (SELECT 1 FROM dbo.Schools WHERE SchoolCode = N'DPSNOIDA')
BEGIN
    PRINT '*** Already seeded (school DPSNOIDA exists). Nothing to do. ***';
    SET NOEXEC ON;
END
GO

/*------------------------------------------------------------------------------
  Everything below is one batch: it relies on table variables, which do not
  survive a GO.
------------------------------------------------------------------------------*/
BEGIN TRY

/* BCrypt (work factor 11) hash of 'admin123', verified against BCrypt.Net-Next
   4.0.3 -- the version the API references. Development only.

   NOT the hash the old SampleData.sql used: that string was 60 characters of the
   right shape but did not verify against 'admin123' (nor anything else), and the
   default password the registration procs handed out was 56 characters, which is
   not a well-formed BCrypt hash at all. Both were placeholders someone typed by
   hand, so no seeded account could ever actually sign in. */
DECLARE @AdminHash NVARCHAR(255) = N'$2a$11$5h2hU20MWEt31LzKAz9zoOn5aPVypsE63IQw5BvfLTTD.q/lxA/wa';

/*==============================================================================
  1. Platform super admin -- SchoolId NULL, the only user allowed to be
     school-less (CK_Users_SchoolScope).

     Written through sp_CreateUserAccount like everybody else, so the Users row,
     the Persons row and the audit columns are produced by the same code path the
     application uses. @ActorUserId is NULL because there is nobody senior to the
     first account: sp_CreateUserAccount then stamps CreatedBy/ModifiedBy with the
     new id, which is why the FK on those columns is satisfied.

     RoleId 1 is SuperAdmin -- fixed by the Roles seed in 01_Schema.sql and named
     by CK_Users_SchoolScope, which is the reason Roles.Id is not an IDENTITY.
==============================================================================*/
DECLARE @SuperAdminId INT, @SuperAdminPersonId INT;

EXEC dbo.sp_CreateUserAccount
     @SchoolId              = NULL,
     @Username              = N'superadmin',
     @Email                 = N'superadmin@platform.local',
     @PasswordHash          = @AdminHash,
     @RoleId                = 1,
     @FirstName             = N'Platform',
     @LastName              = N'Administrator',
     @RequirePasswordChange = 0,
     @ActorUserId           = NULL,
     @UserId                = @SuperAdminId OUTPUT,
     @PersonId              = @SuperAdminPersonId OUTPUT;

PRINT CONCAT('SuperAdmin created: superadmin (UserId ', @SuperAdminId,
             ', PersonId ', @SuperAdminPersonId, ')');

/*==============================================================================
  2. The two schools.

     sp_CreateSchool also seeds, per school: 3 SchoolSequences rows, 7 FeeTypes,
     64 Settings, 72 Subjects (6 per grade, grades 1-12) and the school's first
     admin.
==============================================================================*/
DECLARE @SchoolRes TABLE
(
    Result          NVARCHAR(500),
    SchoolId        INT,
    SchoolCode      NVARCHAR(12),
    AdminUserId     INT,
    AdminUsername   NVARCHAR(80)
);

DECLARE @Schools TABLE
(
    Ord         INT,
    SchoolId    INT,
    SchoolCode  NVARCHAR(12),
    AdminUserId INT
);

INSERT INTO @SchoolRes
EXEC dbo.sp_CreateSchool
     @SchoolCode        = N'DPSNOIDA',
     @SchoolName        = N'Delhi Public School, Noida',
     @Subdomain         = N'dpsnoida',
     @Address           = N'Sector 30, Noida',
     @City              = N'Noida',
     @State             = N'Uttar Pradesh',
     @Country           = N'India',
     @PostalCode        = N'201303',
     @ContactEmail      = N'office@dpsnoida.edu.in',
     @ContactPhone      = N'01202345678',
     @PrincipalName     = N'Dr. Meera Krishnan',
     @ThemeColor        = N'#1976d2',
     @AdminEmail        = N'admin@dpsnoida.edu.in',
     @AdminFirstName    = N'Rakesh',
     @AdminLastName     = N'Gupta',
     @AdminPhoneNumber  = N'9810000001',
     @AdminPasswordHash = @AdminHash,
     @CreatedByUserId   = @SuperAdminId;

IF NOT EXISTS (SELECT 1 FROM @SchoolRes WHERE Result = 'Success')
    THROW 52000, 'Could not create school DPSNOIDA.', 1;

INSERT INTO @Schools (Ord, SchoolId, SchoolCode, AdminUserId)
SELECT 1, SchoolId, SchoolCode, AdminUserId FROM @SchoolRes;

DELETE FROM @SchoolRes;

INSERT INTO @SchoolRes
EXEC dbo.sp_CreateSchool
     @SchoolCode        = N'STMARY',
     @SchoolName        = N'St. Mary Convent School',
     @Subdomain         = N'stmary',
     @Address           = N'Civil Lines, Allahabad',
     @City              = N'Prayagraj',
     @State             = N'Uttar Pradesh',
     @Country           = N'India',
     @PostalCode        = N'211001',
     @ContactEmail      = N'office@stmary.edu.in',
     @ContactPhone      = N'05322345678',
     @PrincipalName     = N'Sister Agnes Thomas',
     @ThemeColor        = N'#2e7d32',
     @AdminEmail        = N'admin@stmary.edu.in',
     @AdminFirstName    = N'Prakash',
     @AdminLastName     = N'Nair',
     @AdminPhoneNumber  = N'9810000002',
     @AdminPasswordHash = @AdminHash,
     @CreatedByUserId   = @SuperAdminId;

IF NOT EXISTS (SELECT 1 FROM @SchoolRes WHERE Result = 'Success')
    THROW 52001, 'Could not create school STMARY.', 1;

INSERT INTO @Schools (Ord, SchoolId, SchoolCode, AdminUserId)
SELECT 2, SchoolId, SchoolCode, AdminUserId FROM @SchoolRes;

/*==============================================================================
  3. Per-school people, defined up front so the loops below stay short.
==============================================================================*/
DECLARE @TeacherSeed TABLE
(
    SchoolCode      NVARCHAR(12),
    Ord             INT,
    FirstName       NVARCHAR(50),
    LastName        NVARCHAR(50),
    Subject         NVARCHAR(100),
    Qualification   NVARCHAR(100),
    Experience      INT,
    Salary          DECIMAL(10,2)
);

INSERT INTO @TeacherSeed (SchoolCode, Ord, FirstName, LastName, Subject, Qualification, Experience, Salary)
VALUES (N'DPSNOIDA', 1, N'Rahul',  N'Sharma',  N'Mathematics', N'M.Sc, B.Ed',  8, 62000),
       (N'DPSNOIDA', 2, N'Anita',  N'Verma',   N'Science',     N'M.Sc, B.Ed', 12, 71000),
       (N'STMARY',   1, N'Joseph', N'Fernandes', N'English',   N'M.A, B.Ed',  10, 58000),
       (N'STMARY',   2, N'Kavita', N'Iyer',    N'Mathematics', N'M.Sc, B.Ed',  6, 54000);

DECLARE @StudentSeed TABLE
(
    SchoolCode  NVARCHAR(12),
    Ord         INT,
    FirstName   NVARCHAR(50),
    LastName    NVARCHAR(50),
    Grade       NVARCHAR(10),
    Gender      NVARCHAR(10),
    FatherName  NVARCHAR(100),
    MotherName  NVARCHAR(100),
    BloodGroup  NVARCHAR(5),
    DateOfBirth DATE
);

INSERT INTO @StudentSeed (SchoolCode, Ord, FirstName, LastName, Grade, Gender, FatherName, MotherName, BloodGroup, DateOfBirth)
VALUES (N'DPSNOIDA', 1, N'Aarav',  N'Mehta',   N'10', N'Male',   N'Nitin Mehta',    N'Priya Mehta',    N'B+',  '2010-05-14'),
       (N'DPSNOIDA', 2, N'Diya',   N'Kapoor',  N'10', N'Female', N'Arun Kapoor',    N'Sneha Kapoor',   N'O+',  '2010-08-02'),
       (N'DPSNOIDA', 3, N'Kabir',  N'Singh',   N'10', N'Male',   N'Jaswant Singh',  N'Harleen Singh',  N'A+',  '2010-11-23'),
       (N'DPSNOIDA', 4, N'Ishita', N'Bansal',  N'9',  N'Female', N'Rohit Bansal',   N'Neha Bansal',    N'AB+', '2011-02-09'),
       (N'DPSNOIDA', 5, N'Vivaan', N'Chauhan', N'9',  N'Male',   N'Dinesh Chauhan', N'Rekha Chauhan',  N'B-',  '2011-06-30'),
       (N'DPSNOIDA', 6, N'Myra',   N'Joshi',   N'9',  N'Female', N'Sameer Joshi',   N'Anjali Joshi',   N'O-',  '2011-09-17'),
       (N'STMARY',   1, N'Aditya', N'Rao',     N'10', N'Male',   N'Venkat Rao',     N'Lakshmi Rao',    N'A+',  '2010-04-21'),
       (N'STMARY',   2, N'Neha',   N'Pillai',  N'10', N'Female', N'Suresh Pillai',  N'Deepa Pillai',   N'B+',  '2010-07-08'),
       (N'STMARY',   3, N'Rohan',  N'D''Souza', N'10', N'Male',  N'Alan D''Souza',   N'Maria D''Souza',  N'O+',  '2010-12-01'),
       (N'STMARY',   4, N'Sanya',  N'Khan',    N'9',  N'Female', N'Imran Khan',     N'Farah Khan',     N'AB-', '2011-01-19'),
       (N'STMARY',   5, N'Arjun',  N'Nambiar', N'9',  N'Male',   N'Ravi Nambiar',   N'Sudha Nambiar',  N'A-',  '2011-05-05'),
       (N'STMARY',   6, N'Tanya',  N'Dutta',   N'9',  N'Female', N'Bikram Dutta',   N'Moushumi Dutta', N'B+',  '2011-10-12');

/*==============================================================================
  4. Classes, teachers and students, school by school.
==============================================================================*/
DECLARE @ClassRes    TABLE (Result NVARCHAR(500), ClassId INT);
DECLARE @TeacherRes  TABLE (Result NVARCHAR(500), UserId INT, TeacherRecordId INT,
                            Username NVARCHAR(80), EmployeeId NVARCHAR(30));
DECLARE @StudentRes  TABLE (Result NVARCHAR(500), UserId INT, StudentRecordId INT,
                            Username NVARCHAR(80), StudentId NVARCHAR(40), RollNumber NVARCHAR(10));

DECLARE @Teachers TABLE (SchoolId INT, Ord INT, TeacherId INT, UserId INT);
DECLARE @Classes  TABLE (SchoolId INT, Grade NVARCHAR(10), ClassId INT);

DECLARE @i INT = 1;
DECLARE @SchoolCount INT = (SELECT COUNT(*) FROM @Schools);

WHILE @i <= @SchoolCount
BEGIN
    DECLARE @SchoolId INT, @Code NVARCHAR(12), @AdminId INT;

    SELECT @SchoolId = SchoolId, @Code = SchoolCode, @AdminId = AdminUserId
    FROM @Schools WHERE Ord = @i;

    PRINT CONCAT('--- Seeding ', @Code, ' (SchoolId ', @SchoolId, ') ---');

    /*-- 4a. Fee type amounts. sp_CreateSchool seeds the names only, because a
           sensible amount is entirely school-specific. ------------------------*/
    UPDATE dbo.FeeTypes
       SET DefaultAmount = CASE FeeTypeName
                             WHEN N'Monthly Fee'   THEN CASE WHEN @Code = N'DPSNOIDA' THEN 3500 ELSE 2200 END
                             WHEN N'Admission Fee' THEN CASE WHEN @Code = N'DPSNOIDA' THEN 25000 ELSE 15000 END
                             WHEN N'Exam Fee'      THEN 1200
                             WHEN N'Library Fee'   THEN 600
                             WHEN N'Lab Fee'       THEN 900
                             WHEN N'Transport Fee' THEN 1800
                             WHEN N'Activity Fee'  THEN 750
                           END,
           UpdatedAt = GETDATE()
     WHERE SchoolId = @SchoolId;

    /*-- 4b. Two classes. ------------------------------------------------------*/
    DELETE FROM @ClassRes;
    INSERT INTO @ClassRes
    EXEC dbo.sp_CreateClass @SchoolId = @SchoolId, @ClassName = N'10-A',
                            @Grade = N'10', @Section = N'A', @MaxStudents = 40;

    INSERT INTO @Classes (SchoolId, Grade, ClassId)
    SELECT @SchoolId, N'10', ClassId FROM @ClassRes WHERE ClassId IS NOT NULL;

    DELETE FROM @ClassRes;
    INSERT INTO @ClassRes
    EXEC dbo.sp_CreateClass @SchoolId = @SchoolId, @ClassName = N'9-B',
                            @Grade = N'9', @Section = N'B', @MaxStudents = 35;

    INSERT INTO @Classes (SchoolId, Grade, ClassId)
    SELECT @SchoolId, N'9', ClassId FROM @ClassRes WHERE ClassId IS NOT NULL;

    /*-- 4c. Teachers. --------------------------------------------------------*/
    DECLARE @t INT = 1;
    WHILE @t <= 2
    BEGIN
        DECLARE @TFirst NVARCHAR(50), @TLast NVARCHAR(50), @TSubject NVARCHAR(100),
                @TQual NVARCHAR(100), @TExp INT, @TSalary DECIMAL(10,2), @TEmail NVARCHAR(100);

        SELECT @TFirst = FirstName, @TLast = LastName, @TSubject = Subject,
               @TQual = Qualification, @TExp = Experience, @TSalary = Salary
        FROM @TeacherSeed WHERE SchoolCode = @Code AND Ord = @t;

        SET @TEmail = LOWER(@TFirst + N'.' + REPLACE(@TLast, N'''', N'') + N'@'
                            + LOWER(@Code) + N'.edu.in');

        DELETE FROM @TeacherRes;
        INSERT INTO @TeacherRes
        EXEC dbo.sp_RegisterTeacher
             @SchoolId          = @SchoolId,
             @FirstName         = @TFirst,
             @LastName          = @TLast,
             @Email             = @TEmail,
             @PhoneNumber       = N'9800000000',
             @Address           = N'Staff quarters',
             @Subject           = @TSubject,
             @Qualification     = @TQual,
             @Experience        = @TExp,
             @Salary            = @TSalary,
             @PerformedByUserId = @AdminId;

        IF NOT EXISTS (SELECT 1 FROM @TeacherRes WHERE Result = 'Success')
            THROW 52002, 'Could not register a seed teacher.', 1;

        INSERT INTO @Teachers (SchoolId, Ord, TeacherId, UserId)
        SELECT @SchoolId, @t, TeacherRecordId, UserId FROM @TeacherRes;

        SET @t += 1;
    END

    /*-- 4d. Class teachers. ClassTeacherId is a Teachers.Id. -----------------*/
    UPDATE c
       SET ClassTeacherId = t.TeacherId,
           UpdatedAt = GETDATE()
    FROM dbo.Classes AS c
    INNER JOIN @Classes  AS sc ON sc.SchoolId = c.SchoolId AND sc.ClassId = c.Id
    INNER JOIN @Teachers AS t  ON t.SchoolId = c.SchoolId
                              AND t.Ord = CASE sc.Grade WHEN N'10' THEN 1 ELSE 2 END
    WHERE c.SchoolId = @SchoolId;

    /*-- 4e. Students. Six each, three per class. -----------------------------*/
    DECLARE @s INT = 1;
    WHILE @s <= 6
    BEGIN
        DECLARE @SFirst NVARCHAR(50), @SLast NVARCHAR(50), @SGrade NVARCHAR(10),
                @SGender NVARCHAR(10), @SFather NVARCHAR(100), @SMother NVARCHAR(100),
                @SBlood NVARCHAR(5), @SDob DATE, @SEmail NVARCHAR(100), @SClassId INT;

        SELECT @SFirst = FirstName, @SLast = LastName, @SGrade = Grade, @SGender = Gender,
               @SFather = FatherName, @SMother = MotherName, @SBlood = BloodGroup,
               @SDob = DateOfBirth
        FROM @StudentSeed WHERE SchoolCode = @Code AND Ord = @s;

        SELECT @SClassId = ClassId FROM @Classes WHERE SchoolId = @SchoolId AND Grade = @SGrade;

        SET @SEmail = LOWER(@SFirst + N'.' + REPLACE(@SLast, N'''', N'') + N'@'
                            + LOWER(@Code) + N'.student.in');

        DELETE FROM @StudentRes;
        INSERT INTO @StudentRes
        EXEC dbo.sp_RegisterStudent
             @SchoolId          = @SchoolId,
             @FirstName         = @SFirst,
             @LastName          = @SLast,
             @Email             = @SEmail,
             @PhoneNumber       = N'9700000000',
             @Address           = N'Residence',
             @ClassId           = @SClassId,
             @DateOfBirth       = @SDob,
             @Gender            = @SGender,
             @FatherName        = @SFather,
             @MotherName        = @SMother,
             @BloodGroup        = @SBlood,
             @PerformedByUserId = @AdminId;

        IF NOT EXISTS (SELECT 1 FROM @StudentRes WHERE Result = 'Success')
            THROW 52003, 'Could not register a seed student.', 1;

        SET @s += 1;
    END

    SET @i += 1;
END

/*==============================================================================
  5. Subject links.

     Teachers teach the subject named on their record, across every grade.
     Students take all six subjects for their own grade.
==============================================================================*/
INSERT INTO dbo.TeacherSubjects (SchoolId, TeacherId, SubjectId)
SELECT t.SchoolId, t.Id, sub.Id
FROM dbo.Teachers AS t
INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = t.SchoolId AND sub.SubjectName = t.Subject
WHERE NOT EXISTS (SELECT 1 FROM dbo.TeacherSubjects AS ts
                   WHERE ts.SchoolId = t.SchoolId AND ts.TeacherId = t.Id
                     AND ts.SubjectId = sub.Id);

INSERT INTO dbo.StudentSubjects (SchoolId, StudentId, SubjectId)
SELECT st.SchoolId, st.Id, sub.Id
FROM dbo.Students AS st
INNER JOIN dbo.Classes  AS c   ON c.SchoolId = st.SchoolId AND c.Id = st.ClassId
INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = st.SchoolId AND sub.Grade = c.Grade
WHERE NOT EXISTS (SELECT 1 FROM dbo.StudentSubjects AS ss
                   WHERE ss.SchoolId = st.SchoolId AND ss.StudentId = st.Id
                     AND ss.SubjectId = sub.Id);

/*==============================================================================
  6. Grade-entry rights and timetable.

     Each teacher gets their subject in each class of a grade they teach, and one
     period a day Monday-Friday. The room is prefixed with the school code so the
     new same-room clash check in sp_CreateOrUpdateScheduleEntry cannot fire
     across schools -- it is per school anyway, this just keeps the demo data
     readable.
==============================================================================*/
INSERT INTO dbo.TeacherSubjectAssignments (SchoolId, TeacherId, SubjectId, ClassId)
SELECT ts.SchoolId, ts.TeacherId, ts.SubjectId, c.Id
FROM dbo.TeacherSubjects AS ts
INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = ts.SchoolId AND sub.Id = ts.SubjectId
INNER JOIN dbo.Classes  AS c   ON c.SchoolId = ts.SchoolId AND c.Grade = sub.Grade
WHERE NOT EXISTS (SELECT 1 FROM dbo.TeacherSubjectAssignments AS a
                   WHERE a.SchoolId = ts.SchoolId AND a.TeacherId = ts.TeacherId
                     AND a.SubjectId = ts.SubjectId AND a.ClassId = c.Id);

/* One period per assignment per weekday. The hour is derived from the class and
   the teacher's ordinal -- grade 10 in the morning, grade 9 after it, each
   teacher an hour apart -- so the seeded timetable satisfies all three clash
   rules sp_CreateOrUpdateScheduleEntry enforces: no teacher, no class and no
   room is ever double-booked. Writing rows that the validating procedure would
   have rejected would make the timetable screens show two lessons at once. */
INSERT INTO dbo.TeacherSchedule (SchoolId, TeacherId, SubjectId, ClassId, DayOfWeek,
                                 StartTime, EndTime, Room)
SELECT a.SchoolId,
       a.TeacherId,
       a.SubjectId,
       a.ClassId,
       d.DayOfWeek,
       TIMEFROMPARTS(h.StartHour,  0, 0, 0, 0),
       TIMEFROMPARTS(h.StartHour, 50, 0, 0, 0),
       sc.SchoolCode + N'-' + c.ClassName
FROM dbo.TeacherSubjectAssignments AS a
INNER JOIN dbo.Classes AS c  ON c.SchoolId = a.SchoolId AND c.Id = a.ClassId
INNER JOIN dbo.Schools AS sc ON sc.Id = a.SchoolId
INNER JOIN @Teachers   AS t  ON t.SchoolId = a.SchoolId AND t.TeacherId = a.TeacherId
CROSS APPLY (SELECT CASE WHEN c.Grade = N'10' THEN 8 ELSE 10 END + t.Ord AS StartHour) AS h
CROSS JOIN (VALUES (1), (2), (3), (4), (5)) AS d(DayOfWeek)
WHERE c.Grade IN (N'10', N'9');

/*==============================================================================
  7. Attendance for the last 20 weekdays.

     The weekday test uses DATEDIFF from 1900-01-01 (a Monday) rather than
     DATEPART(WEEKDAY), which would depend on the session's DATEFIRST.
     Absences follow a fixed pattern so every run produces the same numbers.
==============================================================================*/
DECLARE @Days TABLE (AttendanceDate DATE PRIMARY KEY, DayIndex INT);

INSERT INTO @Days (AttendanceDate, DayIndex)
SELECT d.TheDate, ROW_NUMBER() OVER (ORDER BY d.TheDate)
FROM (SELECT TOP (28) DATEADD(DAY, - ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                              CAST(GETDATE() AS DATE)) AS TheDate
      FROM sys.all_objects) AS d
WHERE (DATEDIFF(DAY, '19000101', d.TheDate) % 7) + 1 <= 5;   -- Monday..Friday

INSERT INTO dbo.Attendance (SchoolId, StudentId, ClassId, AttendanceDate, IsPresent,
                            Remarks, MarkedBy, MarkedAt)
SELECT st.SchoolId,
       st.Id,
       st.ClassId,
       d.AttendanceDate,
       CASE WHEN (st.Id * 7 + d.DayIndex) % 11 = 0 THEN 0 ELSE 1 END,
       CASE WHEN (st.Id * 7 + d.DayIndex) % 11 = 0 THEN N'Informed absence' END,
       ct.UserId,
       CAST(d.AttendanceDate AS DATETIME) + '09:15'
FROM dbo.Students AS st
INNER JOIN dbo.Classes  AS c  ON c.SchoolId = st.SchoolId AND c.Id = st.ClassId
INNER JOIN dbo.Teachers AS ct ON ct.SchoolId = c.SchoolId AND ct.Id = c.ClassTeacherId
CROSS JOIN @Days AS d
WHERE st.IsActive = 1;

/*==============================================================================
  8. One mid-term examination per class per subject taught, plus results.
==============================================================================*/
INSERT INTO dbo.Examinations (SchoolId, ExamName, ExamType, ClassId, SubjectId, ExamDate,
                              MaxMarks, PassingMarks, Duration)
SELECT a.SchoolId,
       N'Mid Term ' + sub.SubjectName + N' (' + c.ClassName + N')',
       N'Mid Term',
       a.ClassId,
       a.SubjectId,
       DATEADD(DAY, -14, CAST(GETDATE() AS DATE)),
       100,
       40,
       120
FROM dbo.TeacherSubjectAssignments AS a
INNER JOIN dbo.Subjects AS sub ON sub.SchoolId = a.SchoolId AND sub.Id = a.SubjectId
INNER JOIN dbo.Classes  AS c   ON c.SchoolId = a.SchoolId AND c.Id = a.ClassId;

/* Marks 41..96, deterministic, then the grade through fn_CalculateGrade so the
   thresholds in each school's AcademicSettings are exercised. */
INSERT INTO dbo.Results (SchoolId, StudentId, ExaminationId, ObtainedMarks, Grade, Remarks)
SELECT st.SchoolId,
       st.Id,
       e.Id,
       41 + ((st.Id * 13 + e.Id * 7) % 56),
       dbo.fn_CalculateGrade(st.SchoolId, 41 + ((st.Id * 13 + e.Id * 7) % 56), e.MaxMarks),
       N'Seeded result'
FROM dbo.Examinations AS e
INNER JOIN dbo.Students AS st ON st.SchoolId = e.SchoolId AND st.ClassId = e.ClassId
WHERE st.IsActive = 1;

/*==============================================================================
  9. Fees: the last three months of Monthly Fee, plus Exam Fee, per student.
     The oldest month is already past due, which gives the dashboard's
     OverdueFees and sp_GetOutstandingFees something real to report.
==============================================================================*/
DECLARE @Today DATE = CAST(GETDATE() AS DATE);

INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
SELECT st.SchoolId,
       st.Id,
       ft.Id,
       ft.DefaultAmount,
       EOMONTH(DATEADD(MONTH, m.Offset, @Today)),
       MONTH(DATEADD(MONTH, m.Offset, @Today)),
       YEAR(DATEADD(MONTH, m.Offset, @Today))
FROM dbo.Students AS st
INNER JOIN dbo.FeeTypes AS ft ON ft.SchoolId = st.SchoolId AND ft.FeeTypeName = N'Monthly Fee'
CROSS JOIN (VALUES (-2), (-1), (0)) AS m(Offset)
WHERE st.IsActive = 1;

INSERT INTO dbo.Fees (SchoolId, StudentId, FeeTypeId, Amount, DueDate, FeeMonth, FeeYear)
SELECT st.SchoolId,
       st.Id,
       ft.Id,
       ft.DefaultAmount,
       EOMONTH(DATEADD(MONTH, -1, @Today)),
       MONTH(DATEADD(MONTH, -1, @Today)),
       YEAR(DATEADD(MONTH, -1, @Today))
FROM dbo.Students AS st
INNER JOIN dbo.FeeTypes AS ft ON ft.SchoolId = st.SchoolId AND ft.FeeTypeName = N'Exam Fee'
WHERE st.IsActive = 1;

/*==============================================================================
 10. One real payment per school through sp_MakeFeePayment, so at least one
     receipt number is drawn from SchoolSequences and the balance arithmetic in
     sp_GetStudentFees has both a paid and an unpaid case to show.
==============================================================================*/
DECLARE @PayRes TABLE (Result NVARCHAR(500), PaymentId INT, ReceiptNumber NVARCHAR(40));

DECLARE @p INT = 1;
WHILE @p <= @SchoolCount
BEGIN
    DECLARE @PaySchool INT, @PayAdmin INT, @FeeId INT, @FeeAmount DECIMAL(10,2);

    SELECT @PaySchool = SchoolId, @PayAdmin = AdminUserId FROM @Schools WHERE Ord = @p;

    SELECT TOP 1 @FeeId = f.Id, @FeeAmount = f.Amount
    FROM dbo.Fees AS f
    WHERE f.SchoolId = @PaySchool
    ORDER BY f.DueDate, f.Id;

    DELETE FROM @PayRes;
    INSERT INTO @PayRes
    EXEC dbo.sp_MakeFeePayment
         @SchoolId      = @PaySchool,
         @FeeId         = @FeeId,
         @AmountPaid    = @FeeAmount,
         @PaymentMethod = N'Cash',
         @TransactionId = NULL,
         @Remarks       = N'Seed payment',
         @PaidBy        = @PayAdmin;

    IF NOT EXISTS (SELECT 1 FROM @PayRes WHERE Result = 'Success')
        THROW 52004, 'Could not record a seed fee payment.', 1;

    SET @p += 1;
END

/*==============================================================================
 11. What was created.
==============================================================================*/
SELECT sc.Id AS SchoolId,
       sc.SchoolCode,
       sc.SchoolName,
       sc.Subdomain,
       (SELECT COUNT(*) FROM dbo.Users     WHERE SchoolId = sc.Id) AS Users,
       (SELECT COUNT(*) FROM dbo.Persons   WHERE SchoolId = sc.Id) AS Persons,
       (SELECT COUNT(*) FROM dbo.Addresses WHERE SchoolId = sc.Id) AS Addresses,
       (SELECT COUNT(*) FROM dbo.Classes   WHERE SchoolId = sc.Id) AS Classes,
       (SELECT COUNT(*) FROM dbo.Teachers  WHERE SchoolId = sc.Id) AS Teachers,
       (SELECT COUNT(*) FROM dbo.Students  WHERE SchoolId = sc.Id) AS Students,
       (SELECT COUNT(*) FROM dbo.Subjects  WHERE SchoolId = sc.Id) AS Subjects,
       (SELECT COUNT(*) FROM dbo.Settings  WHERE SchoolId = sc.Id) AS Settings,
       (SELECT COUNT(*) FROM dbo.TeacherSchedule WHERE SchoolId = sc.Id) AS SchedulePeriods,
       (SELECT COUNT(*) FROM dbo.Attendance WHERE SchoolId = sc.Id) AS AttendanceRows,
       (SELECT COUNT(*) FROM dbo.Examinations WHERE SchoolId = sc.Id) AS Examinations,
       (SELECT COUNT(*) FROM dbo.Results    WHERE SchoolId = sc.Id) AS Results,
       (SELECT COUNT(*) FROM dbo.Fees       WHERE SchoolId = sc.Id) AS Fees,
       (SELECT COUNT(*) FROM dbo.FeePayments WHERE SchoolId = sc.Id) AS Payments
FROM dbo.Schools AS sc
ORDER BY sc.Id;

/* Reads vw_Users so Role still comes back as a name; the underlying column is
   now Users.RoleId. Roles 1 and 2 are SuperAdmin and Admin. */
SELECT u.Username, u.Role, u.FirstName, u.LastName, sc.SchoolCode,
       N'admin123' AS Password
FROM dbo.vw_Users AS u
LEFT JOIN dbo.Schools AS sc ON sc.Id = u.SchoolId
WHERE u.RoleId IN (1, 2)
ORDER BY u.Id;

/* The permission grid as seeded, so a reviewer can see at a glance what each
   role may do before the first login. */
SELECT r.Id AS RoleId, r.RoleName, r.RoleCode,
       COUNT(rp.Id) AS Modules,
       SUM(CAST(rp.CanView   AS INT)) AS CanView,
       SUM(CAST(rp.CanCreate AS INT)) AS CanCreate,
       SUM(CAST(rp.CanEdit   AS INT)) AS CanEdit,
       SUM(CAST(rp.CanDelete AS INT)) AS CanDelete
FROM dbo.Roles AS r
LEFT JOIN dbo.RolePermissions AS rp ON rp.RoleId = r.Id
GROUP BY r.Id, r.RoleName, r.RoleCode
ORDER BY r.Id;

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT '*** SEED FAILED ***';
    THROW;
END CATCH
GO

PRINT '=== 15_Seed.sql complete ===';
GO

SET NOEXEC OFF;
GO
