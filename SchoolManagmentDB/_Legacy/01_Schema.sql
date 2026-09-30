/*==============================================================================
  01_Schema.sql  --  Multi-school (multi-tenant) schema
  ------------------------------------------------------------------------------
  One database, one API, one URL, many schools.

  TENANCY MODEL
    Every tenant-owned table carries SchoolId INT NOT NULL.
    Schools, Roles and RolePermissions are the tenant-free tables.
    Users.SchoolId, Persons.SchoolId and Addresses.SchoolId are NULL for exactly
    one kind of row: the platform SuperAdmin.

  IDENTITY MODEL
    Users holds credentials only (Username, Email, PasswordHash, RoleId).
    Persons holds the human (names, phone, photo). Addresses holds postal detail.
    Roles + RolePermissions replace the old Users.Role string with a per-module
    CanView/CanCreate/CanEdit/CanDelete grid. See SECTION 2.
    dbo.vw_Users (SECTION 8) re-flattens all of it into the pre-split column list
    so read-only procedures and their DTOs did not change.

  AUDIT COLUMNS
    Users, Persons, Addresses, Roles and RolePermissions each carry
    CreatedBy / ModifiedBy referencing Users.Id, so every row records who made it
    and who last touched it. Procedures take @CreatedBy / @ModifiedBy; the API
    passes the caller's id from the JWT.

  ISOLATION GUARD
    Row-Level Security is deliberately not used, so the composite foreign keys
    below are the ONLY structural defence against a query mixing two schools'
    rows. Every parent table carries UNIQUE (SchoolId, Id) purely so children
    can point at it with (SchoolId, <fk>). Do not "simplify" these away.

    Effect: School A's student cannot be enrolled in School B's class, given a
    result for School B's exam, or billed School B's fee type -- even if a
    stored procedure forgets a WHERE SchoolId clause.

  DATE/TIME CONVENTION
    CreatedAt / UpdatedAt / attendance / fees use GETDATE() (server local time),
    matching the existing application's display behaviour.
    RefreshTokens.ExpiryDate is UTC, because the API computes it with
    DateTime.UtcNow (AuthController.cs:45). Procedures touching it use
    GETUTCDATE(). Mixing the two is what makes tokens expire early.

  Run after 00_Drop_All.sql.
==============================================================================*/

/* Required for the filtered indexes below; sqlcmd defaults QUOTED_IDENTIFIER OFF. */
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

/* This script builds the schema from nothing; it is not a migration. Stopping
   here beats emitting twenty "there is already an object named ..." errors and
   leaving a half-applied schema behind. Run 00_Drop_All.sql for a rebuild. */
IF OBJECT_ID(N'dbo.Schools', N'U') IS NOT NULL
BEGIN
    PRINT '*** SKIPPED: the schema already exists in [' + DB_NAME() + ']. ***';
    PRINT '*** Run 00_Drop_All.sql first if you intend to rebuild it. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  SECTION 1 -- PLATFORM TABLES
==============================================================================*/

/*------------------------------------------------------------------------------
  Schools -- the tenant registry. The only table without a SchoolId.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Schools (
    Id                      INT             IDENTITY(1,1)   NOT NULL,
    SchoolCode              NVARCHAR(12)                    NOT NULL,
    SchoolName              NVARCHAR(150)                   NOT NULL,
    Subdomain               NVARCHAR(63)                    NULL,
    Address                 NVARCHAR(255)                   NULL,
    City                    NVARCHAR(80)                    NULL,
    State                   NVARCHAR(80)                    NULL,
    Country                 NVARCHAR(80)                    NULL,
    PostalCode              NVARCHAR(20)                    NULL,
    ContactEmail            NVARCHAR(100)                   NULL,
    ContactPhone            NVARCHAR(20)                    NULL,
    PrincipalName           NVARCHAR(100)                   NULL,
    LogoUrl                 NVARCHAR(500)                   NULL,
    ThemeColor              NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_Schools_ThemeColor DEFAULT ('#1976d2'),
    AcademicYearStartMonth  TINYINT                         NOT NULL
        CONSTRAINT DF_Schools_AcademicYearStartMonth DEFAULT (4),
    IsActive                BIT                             NOT NULL
        CONSTRAINT DF_Schools_IsActive DEFAULT (1),
    CreatedAt               DATETIME                        NOT NULL
        CONSTRAINT DF_Schools_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt               DATETIME                        NOT NULL
        CONSTRAINT DF_Schools_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Schools PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Schools_SchoolCode UNIQUE (SchoolCode),

    /* SchoolCode is embedded verbatim into usernames and student IDs, so it
       must be A-Z0-9 only. The BIN collation matters: under the default
       case-insensitive collation, '[^A-Z0-9]' would happily accept lowercase. */
    CONSTRAINT CK_Schools_SchoolCode CHECK (
        LEN(SchoolCode) BETWEEN 3 AND 12
        AND SchoolCode COLLATE Latin1_General_BIN NOT LIKE '%[^A-Z0-9]%'
    ),
    CONSTRAINT CK_Schools_Subdomain CHECK (
        Subdomain IS NULL
        OR (LEN(Subdomain) BETWEEN 2 AND 63
            AND Subdomain COLLATE Latin1_General_BIN NOT LIKE '%[^a-z0-9-]%'
            AND Subdomain NOT LIKE '-%'
            AND Subdomain NOT LIKE '%-')
    ),
    CONSTRAINT CK_Schools_AcademicYearStartMonth CHECK (AcademicYearStartMonth BETWEEN 1 AND 12)
);
GO

/* Filtered, because Subdomain is optional and many schools may have none. */
CREATE UNIQUE INDEX UX_Schools_Subdomain
    ON dbo.Schools (Subdomain)
    WHERE Subdomain IS NOT NULL;
GO

/*------------------------------------------------------------------------------
  SchoolSequences -- per-school counters.

  Replaces the old "(SELECT COUNT(*) + 1 FROM Students WHERE ClassId = @x)"
  pattern, which handed the same number to two concurrent registrations and
  re-used numbers after a delete.

  SequenceName values in use:
      'Student'          admission serial, per school
      'Employee'         employee serial, per school
      'Receipt'          fee receipt serial, per school
      'Roll:<ClassId>'   roll number, per school + class
------------------------------------------------------------------------------*/
CREATE TABLE dbo.SchoolSequences (
    SchoolId        INT             NOT NULL,
    SequenceName    NVARCHAR(50)    NOT NULL,
    LastValue       INT             NOT NULL
        CONSTRAINT DF_SchoolSequences_LastValue DEFAULT (0),
    UpdatedAt       DATETIME        NOT NULL
        CONSTRAINT DF_SchoolSequences_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_SchoolSequences PRIMARY KEY CLUSTERED (SchoolId, SequenceName),
    CONSTRAINT FK_SchoolSequences_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO

/*==============================================================================
  SECTION 2 -- IDENTITY

  The identity of a human is split across three tables:

      Persons     who they are        FirstName, LastName, phone, photo
      Users       how they log in     Username, Email, PasswordHash, RoleId
      Addresses   where they live     one or more typed postal addresses

  Users holds NOTHING but account/credential data. Anything descriptive lives on
  the Persons row it points at. That is what lets a person keep one identity
  while their login is disabled, renamed, or re-roled.

  Roles / RolePermissions replace the old Users.Role NVARCHAR column.

  READING THE OLD SHAPE
    dbo.vw_Users (bottom of this file) re-joins the three tables and exposes the
    flat pre-split column list -- FirstName, LastName, PhoneNumber, Address,
    Role. Every read-only procedure selects from the view, so result-set column
    names did not change. Only procedures that WRITE were rewritten.
==============================================================================*/

/*------------------------------------------------------------------------------
  Roles -- platform-wide, NOT per school.

  There is no SchoolId here on purpose: 'Teacher' means the same thing in every
  school, and the JWT 'role' claim is compared against these names by
  [Authorize(Roles = ...)] across the whole API.

  THE IDs ARE A CONTRACT, NOT AN ACCIDENT
    Id is explicit rather than IDENTITY and the five system roles are seeded in
    this file, immediately below. CK_Users_SchoolScope has to name the SuperAdmin
    role by number because a CHECK constraint cannot join to another table, so
    that number must be stable and must be defined in the same script that
    depends on it. Constants.RoleIds in C# mirrors these values.

        1  SuperAdmin      2  Admin      3  Teacher      4  Student      5  Parent

    Custom roles added later use Id >= 100 (see DF/CK below) so they can never
    collide with a system role added in a future version.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Roles (
    Id              INT                             NOT NULL,   -- explicit; see above
    RoleName        NVARCHAR(50)                    NOT NULL,
    RoleCode        NVARCHAR(20)                    NOT NULL,
    Description     NVARCHAR(255)                   NULL,
    /* A system role cannot be renamed or deleted: authorization attributes are
       compiled against its name. */
    IsSystemRole    BIT                             NOT NULL
        CONSTRAINT DF_Roles_IsSystemRole DEFAULT (0),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Roles_IsActive DEFAULT (1),
    CreatedBy       INT                             NULL,   -- Users.Id, FK added below
    ModifiedBy      INT                             NULL,   -- Users.Id, FK added below
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Roles_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Roles_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Roles PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Roles_RoleName UNIQUE (RoleName),
    CONSTRAINT UQ_Roles_RoleCode UNIQUE (RoleCode),
    CONSTRAINT CK_Roles_Id CHECK (Id BETWEEN 1 AND 5 OR Id >= 100)
);
GO

/*------------------------------------------------------------------------------
  RolePermissions -- what a role may do, per functional module.

  One row per (role, module). A missing row means "no access at all", so a new
  module is denied by default until someone grants it -- fail closed.

  ModuleName values are the Constants.Modules list in C#; keep the two in step.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.RolePermissions (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    RoleId          INT                             NOT NULL,
    ModuleName      NVARCHAR(50)                    NOT NULL,
    CanView         BIT                             NOT NULL
        CONSTRAINT DF_RolePermissions_CanView DEFAULT (0),
    CanCreate       BIT                             NOT NULL
        CONSTRAINT DF_RolePermissions_CanCreate DEFAULT (0),
    CanEdit         BIT                             NOT NULL
        CONSTRAINT DF_RolePermissions_CanEdit DEFAULT (0),
    CanDelete       BIT                             NOT NULL
        CONSTRAINT DF_RolePermissions_CanDelete DEFAULT (0),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_RolePermissions_IsActive DEFAULT (1),
    CreatedBy       INT                             NULL,   -- Users.Id, FK added below
    ModifiedBy      INT                             NULL,   -- Users.Id, FK added below
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_RolePermissions_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_RolePermissions_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_RolePermissions PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_RolePermissions_Role_Module UNIQUE (RoleId, ModuleName),
    CONSTRAINT FK_RolePermissions_Role FOREIGN KEY (RoleId) REFERENCES dbo.Roles (Id)
);
GO
CREATE INDEX IX_RolePermissions_Role ON dbo.RolePermissions (RoleId) INCLUDE (ModuleName, CanView, CanCreate, CanEdit, CanDelete);
GO

/*------------------------------------------------------------------------------
  Persons -- the human. One row per person, whatever roles they hold.

  SchoolId is nullable for the same single reason Users.SchoolId is: the platform
  SuperAdmin belongs to no tenant.

  This table deliberately does NOT carry DateOfBirth or Gender. Students already
  own those columns, and duplicating them here would create two answers to the
  same question. Only the columns that genuinely moved off Users live here.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Persons (
    Id                          INT             IDENTITY(1,1)   NOT NULL,
    SchoolId                    INT                             NULL,   -- NULL only for SuperAdmin
    FirstName                   NVARCHAR(50)                    NOT NULL,
    LastName                    NVARCHAR(50)                    NOT NULL,
    PhoneNumber                 NVARCHAR(15)                    NULL,
    AlternatePhoneNumber        NVARCHAR(15)                    NULL,
    ProfilePicture              VARBINARY(MAX)                  NULL,
    ProfilePictureFileName      NVARCHAR(255)                   NULL,
    ProfilePictureContentType   NVARCHAR(100)                   NULL,
    ProfilePictureUploadDate    DATETIME                        NULL,
    IsActive                    BIT                             NOT NULL
        CONSTRAINT DF_Persons_IsActive DEFAULT (1),
    CreatedBy                   INT                             NULL,   -- Users.Id, FK added below
    ModifiedBy                  INT                             NULL,   -- Users.Id, FK added below
    CreatedAt                   DATETIME                        NOT NULL
        CONSTRAINT DF_Persons_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt                   DATETIME                        NOT NULL
        CONSTRAINT DF_Persons_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Persons PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_Persons_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO

/* Composite-FK target for Users.PersonId and Addresses.PersonId. */
CREATE UNIQUE INDEX UX_Persons_School_Id ON dbo.Persons (SchoolId, Id);
GO
CREATE INDEX IX_Persons_School_Name ON dbo.Persons (SchoolId, LastName, FirstName) INCLUDE (IsActive);
GO

/*------------------------------------------------------------------------------
  Users -- login accounts. Credentials and role only.

  Username stays GLOBALLY unique because the school code is baked into the
  generated value (DPSNOIDA_S_2025_10A_001). That is what lets sp_Login keep
  its (@Username, @Password) signature and the login page stay unchanged.

  Email is unique PER SCHOOL: the same parent may have children at two schools.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Users (
    Id                          INT             IDENTITY(1,1)   NOT NULL,
    SchoolId                    INT                             NULL,   -- NULL only for SuperAdmin
    PersonId                    INT                             NOT NULL,
    Username                    NVARCHAR(80)                    NOT NULL,
    Email                       NVARCHAR(100)                   NOT NULL,
    PasswordHash                NVARCHAR(255)                   NOT NULL,
    RoleId                      INT                             NOT NULL,
    IsActive                    BIT                             NOT NULL
        CONSTRAINT DF_Users_IsActive DEFAULT (1),
    RequirePasswordChange       BIT                             NOT NULL
        CONSTRAINT DF_Users_RequirePasswordChange DEFAULT (0),
    LastLoginAt                 DATETIME                        NULL,
    CreatedBy                   INT                             NULL,   -- Users.Id
    ModifiedBy                  INT                             NULL,   -- Users.Id
    CreatedAt                   DATETIME                        NOT NULL
        CONSTRAINT DF_Users_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt                   DATETIME                        NOT NULL
        CONSTRAINT DF_Users_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Users PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Users_Username UNIQUE (Username),
    CONSTRAINT UQ_Users_School_Email UNIQUE (SchoolId, Email),

    /* One login per person. Drop this if a person ever needs two accounts;
       nothing else in the schema assumes it. */
    CONSTRAINT UQ_Users_PersonId UNIQUE (PersonId),

    CONSTRAINT FK_Users_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Users_Role   FOREIGN KEY (RoleId)   REFERENCES dbo.Roles (Id),

    /* Composite, so a School A user cannot point at a School B person. Unchecked
       for the SuperAdmin row alone, whose SchoolId is NULL -- SQL Server skips a
       composite FK when any of its columns is NULL. That is the same trade-off
       the other tenant FKs make. */
    CONSTRAINT FK_Users_Person FOREIGN KEY (SchoolId, PersonId)
        REFERENCES dbo.Persons (SchoolId, Id),

    /* Single-column on purpose: a SuperAdmin (SchoolId NULL) legitimately creates
       a school's first Admin, so the actor and the row need not share a tenant. */
    CONSTRAINT FK_Users_CreatedBy  FOREIGN KEY (CreatedBy)  REFERENCES dbo.Users (Id),
    CONSTRAINT FK_Users_ModifiedBy FOREIGN KEY (ModifiedBy) REFERENCES dbo.Users (Id),

    /* A SuperAdmin belongs to the platform, not a school; everyone else must
       belong to exactly one school. Enforced here so no procedure can create
       an orphaned tenant user. RoleId 1 is SuperAdmin -- see the Roles header
       for why this is a literal and not a lookup. */
    CONSTRAINT CK_Users_SchoolScope CHECK (
        (RoleId =  1 AND SchoolId IS NULL)
     OR (RoleId <> 1 AND SchoolId IS NOT NULL)
    )
);
GO

/* Composite-FK target. Nullable SchoolId is fine: child SchoolId is NOT NULL,
   so a tenant row can never match the SuperAdmin's NULL. */
CREATE UNIQUE INDEX UX_Users_School_Id ON dbo.Users (SchoolId, Id);
GO
CREATE INDEX IX_Users_School_Role       ON dbo.Users (SchoolId, RoleId) INCLUDE (IsActive);
CREATE INDEX IX_Users_Username          ON dbo.Users (Username);
CREATE INDEX IX_Users_School_Email      ON dbo.Users (SchoolId, Email);
CREATE INDEX IX_Users_PersonId          ON dbo.Users (PersonId);
GO

/*------------------------------------------------------------------------------
  Addresses -- typed postal addresses, one to many per person.

  The old schema had a single free-text Users.Address NVARCHAR(255). A person can
  now hold a Permanent and a Current address separately, which is what report
  cards and transport routing actually need.

  vw_Users.Address re-flattens the primary address back into one string so the
  existing API contract is unchanged.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Addresses (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NULL,   -- NULL only for SuperAdmin
    PersonId        INT                             NOT NULL,
    AddressType     NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_Addresses_AddressType DEFAULT ('Permanent'),
    AddressLine1    NVARCHAR(255)                   NOT NULL,
    AddressLine2    NVARCHAR(255)                   NULL,
    Landmark        NVARCHAR(100)                   NULL,
    City            NVARCHAR(80)                    NULL,
    State           NVARCHAR(80)                    NULL,
    Country         NVARCHAR(80)                    NULL,
    PostalCode      NVARCHAR(20)                    NULL,
    IsPrimary       BIT                             NOT NULL
        CONSTRAINT DF_Addresses_IsPrimary DEFAULT (0),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Addresses_IsActive DEFAULT (1),
    CreatedBy       INT                             NULL,   -- Users.Id, FK added below
    ModifiedBy      INT                             NULL,   -- Users.Id, FK added below
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Addresses_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Addresses_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Addresses PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Addresses_Person_Type UNIQUE (PersonId, AddressType),
    CONSTRAINT FK_Addresses_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Addresses_Person FOREIGN KEY (SchoolId, PersonId)
        REFERENCES dbo.Persons (SchoolId, Id)
);
GO

/* At most one primary address per person, so vw_Users.Address is deterministic. */
CREATE UNIQUE INDEX UX_Addresses_Person_Primary
    ON dbo.Addresses (PersonId)
    WHERE IsPrimary = 1;
GO
CREATE INDEX IX_Addresses_Person ON dbo.Addresses (PersonId) INCLUDE (IsActive, IsPrimary);
GO

/*------------------------------------------------------------------------------
  Audit FKs that could not be declared inline.

  Roles, RolePermissions, Persons and Addresses are all created before Users
  (Users points at Roles and Persons), so their CreatedBy / ModifiedBy columns
  get their foreign keys here instead.
------------------------------------------------------------------------------*/
ALTER TABLE dbo.Roles
    ADD CONSTRAINT FK_Roles_CreatedBy  FOREIGN KEY (CreatedBy)  REFERENCES dbo.Users (Id),
        CONSTRAINT FK_Roles_ModifiedBy FOREIGN KEY (ModifiedBy) REFERENCES dbo.Users (Id);
GO
ALTER TABLE dbo.RolePermissions
    ADD CONSTRAINT FK_RolePermissions_CreatedBy  FOREIGN KEY (CreatedBy)  REFERENCES dbo.Users (Id),
        CONSTRAINT FK_RolePermissions_ModifiedBy FOREIGN KEY (ModifiedBy) REFERENCES dbo.Users (Id);
GO
ALTER TABLE dbo.Persons
    ADD CONSTRAINT FK_Persons_CreatedBy  FOREIGN KEY (CreatedBy)  REFERENCES dbo.Users (Id),
        CONSTRAINT FK_Persons_ModifiedBy FOREIGN KEY (ModifiedBy) REFERENCES dbo.Users (Id);
GO
ALTER TABLE dbo.Addresses
    ADD CONSTRAINT FK_Addresses_CreatedBy  FOREIGN KEY (CreatedBy)  REFERENCES dbo.Users (Id),
        CONSTRAINT FK_Addresses_ModifiedBy FOREIGN KEY (ModifiedBy) REFERENCES dbo.Users (Id);
GO

/*------------------------------------------------------------------------------
  Role reference data.

  Seeded HERE, not in 15_Seed.sql, for two reasons: CK_Users_SchoolScope names
  RoleId 1, so the schema is not self-consistent without these rows; and roles
  are system reference data, whereas 15_Seed.sql creates disposable demo tenants.

  CreatedBy stays NULL: there is no user yet to attribute this to.
------------------------------------------------------------------------------*/
INSERT INTO dbo.Roles (Id, RoleName, RoleCode, Description, IsSystemRole)
VALUES (1, N'SuperAdmin', N'SUPERADMIN', N'Platform operator. Belongs to no school; manages every tenant.', 1),
       (2, N'Admin',      N'ADMIN',      N'School administrator. Full control within their own school.',      1),
       (3, N'Teacher',    N'TEACHER',    N'Teaching staff. Attendance, grades and their own timetable.',       1),
       (4, N'Student',    N'STUDENT',    N'Enrolled student. Reads their own records.',                        1),
       (5, N'Parent',     N'PARENT',     N'Guardian. Reads the records of their linked children.',             1);
GO

/*------------------------------------------------------------------------------
  Default permissions per system role.

  A role with no row for a module has no access to it, so this grid IS the
  authorization policy. It mirrors what the controllers already enforced with
  [Authorize(Roles = ...)]; the difference is that it is now data an admin can
  change without a redeploy.

  Read the flag columns as CanView / CanCreate / CanEdit / CanDelete.
------------------------------------------------------------------------------*/
;WITH Modules AS (
    SELECT * FROM (VALUES
        (N'Schools'), (N'Users'), (N'Roles'), (N'Students'), (N'Teachers'),
        (N'Parents'), (N'Classes'), (N'Subjects'), (N'Attendance'),
        (N'Examinations'), (N'Results'), (N'Fees'), (N'Schedule'),
        (N'Settings'), (N'Reports')
    ) AS v(ModuleName)
)
INSERT INTO dbo.RolePermissions (RoleId, ModuleName, CanView, CanCreate, CanEdit, CanDelete)
/*--- SuperAdmin: everything, everywhere. ------------------------------------*/
SELECT 1, ModuleName, 1, 1, 1, 1 FROM Modules
UNION ALL
/*--- Admin: everything inside their school, except platform tenancy, which
      they may see (their own school's branding) but not create or delete. ---*/
SELECT 2, ModuleName,
       1,
       CASE WHEN ModuleName = N'Schools' THEN 0 ELSE 1 END,
       1,
       CASE WHEN ModuleName IN (N'Schools', N'Roles') THEN 0 ELSE 1 END
FROM Modules
UNION ALL
/*--- Teacher: owns attendance and grades, reads the rest of the academic
      picture, touches nothing financial or administrative. -----------------*/
SELECT 3, ModuleName, 1, 1, 1, 0
FROM Modules WHERE ModuleName IN (N'Attendance', N'Results')
UNION ALL
SELECT 3, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Students', N'Classes', N'Subjects',
                                  N'Examinations', N'Schedule', N'Reports')
UNION ALL
/*--- Student: read-only on their own records. ------------------------------*/
SELECT 4, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Attendance', N'Results', N'Examinations',
                                  N'Fees', N'Schedule', N'Subjects')
UNION ALL
/*--- Parent: same reads as their children, plus paying the bill. -----------*/
SELECT 5, ModuleName, 1, 0, 0, 0
FROM Modules WHERE ModuleName IN (N'Students', N'Attendance', N'Results',
                                  N'Examinations', N'Schedule')
UNION ALL
SELECT 5, N'Fees', 1, 1, 0, 0;
GO

/*==============================================================================
  SECTION 3 -- ACADEMIC STRUCTURE
==============================================================================*/

/*------------------------------------------------------------------------------
  Teachers -- created before Classes because Classes.ClassTeacherId points here.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Teachers (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    UserId          INT                             NOT NULL,
    EmployeeId      NVARCHAR(30)                    NOT NULL,
    Subject         NVARCHAR(100)                   NULL,   -- free-text primary subject (legacy display field)
    Qualification   NVARCHAR(255)                   NULL,
    Experience      INT                             NULL,
    Salary          DECIMAL(10,2)                   NULL,
    JoinDate        DATE                            NOT NULL
        CONSTRAINT DF_Teachers_JoinDate DEFAULT (GETDATE()),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Teachers_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Teachers_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Teachers_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Teachers PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Teachers_UserId UNIQUE (UserId),
    CONSTRAINT UQ_Teachers_School_EmployeeId UNIQUE (SchoolId, EmployeeId),
    CONSTRAINT FK_Teachers_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Teachers_User FOREIGN KEY (SchoolId, UserId) REFERENCES dbo.Users (SchoolId, Id)
);
GO
CREATE UNIQUE INDEX UX_Teachers_School_Id ON dbo.Teachers (SchoolId, Id);
CREATE INDEX IX_Teachers_School_IsActive  ON dbo.Teachers (SchoolId, IsActive);
GO

/*------------------------------------------------------------------------------
  Classes
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Classes (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    ClassName       NVARCHAR(50)                    NOT NULL,
    Grade           NVARCHAR(10)                    NOT NULL,
    Section         NVARCHAR(5)                     NOT NULL,
    ClassTeacherId  INT                             NULL,   -- Teachers.Id
    MaxStudents     INT                             NOT NULL
        CONSTRAINT DF_Classes_MaxStudents DEFAULT (50),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Classes_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Classes_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Classes_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Classes PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Classes_School_ClassName UNIQUE (SchoolId, ClassName),
    CONSTRAINT UQ_Classes_School_GradeSection UNIQUE (SchoolId, Grade, Section),
    CONSTRAINT FK_Classes_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Classes_ClassTeacher
        FOREIGN KEY (SchoolId, ClassTeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT CK_Classes_MaxStudents CHECK (MaxStudents > 0)
);
GO
CREATE UNIQUE INDEX UX_Classes_School_Id ON dbo.Classes (SchoolId, Id);
CREATE INDEX IX_Classes_School_IsActive  ON dbo.Classes (SchoolId, IsActive);
GO

/*------------------------------------------------------------------------------
  Students
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Students (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    UserId          INT                             NOT NULL,
    StudentId       NVARCHAR(40)                    NOT NULL,   -- human-readable admission number
    ClassId         INT                             NULL,
    RollNumber      NVARCHAR(10)                    NULL,
    DateOfBirth     DATE                            NULL,
    Gender          NVARCHAR(10)                    NULL,
    FatherName      NVARCHAR(100)                   NULL,
    MotherName      NVARCHAR(100)                   NULL,
    AdmissionDate   DATE                            NOT NULL
        CONSTRAINT DF_Students_AdmissionDate DEFAULT (GETDATE()),
    BloodGroup      NVARCHAR(5)                     NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Students_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Students_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Students_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Students PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Students_UserId UNIQUE (UserId),
    CONSTRAINT UQ_Students_School_StudentId UNIQUE (SchoolId, StudentId),
    CONSTRAINT FK_Students_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Students_User FOREIGN KEY (SchoolId, UserId) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT FK_Students_Class FOREIGN KEY (SchoolId, ClassId) REFERENCES dbo.Classes (SchoolId, Id),
    CONSTRAINT CK_Students_Gender CHECK (Gender IS NULL OR Gender IN ('Male', 'Female', 'Other'))
);
GO
CREATE UNIQUE INDEX UX_Students_School_Id  ON dbo.Students (SchoolId, Id);
CREATE INDEX IX_Students_School_Class      ON dbo.Students (SchoolId, ClassId) INCLUDE (IsActive, RollNumber);
CREATE INDEX IX_Students_School_StudentId  ON dbo.Students (SchoolId, StudentId);
GO

/* Roll numbers are unique within a class, but only where one is assigned. */
CREATE UNIQUE INDEX UX_Students_School_Class_Roll
    ON dbo.Students (SchoolId, ClassId, RollNumber)
    WHERE ClassId IS NOT NULL AND RollNumber IS NOT NULL;
GO

/*------------------------------------------------------------------------------
  Parents
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Parents (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    UserId          INT                             NOT NULL,
    Occupation      NVARCHAR(100)                   NULL,
    AnnualIncome    DECIMAL(12,2)                   NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Parents_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Parents_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Parents_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Parents PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Parents_UserId UNIQUE (UserId),
    CONSTRAINT FK_Parents_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Parents_User FOREIGN KEY (SchoolId, UserId) REFERENCES dbo.Users (SchoolId, Id)
);
GO
CREATE UNIQUE INDEX UX_Parents_School_Id ON dbo.Parents (SchoolId, Id);
GO

/*------------------------------------------------------------------------------
  StudentParents -- many-to-many
------------------------------------------------------------------------------*/
CREATE TABLE dbo.StudentParents (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ParentId        INT                             NOT NULL,   -- Parents.Id
    Relationship    NVARCHAR(20)                    NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_StudentParents_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_StudentParents_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_StudentParents PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_StudentParents UNIQUE (SchoolId, StudentId, ParentId),
    CONSTRAINT FK_StudentParents_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_StudentParents_Student
        FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_StudentParents_Parent
        FOREIGN KEY (SchoolId, ParentId) REFERENCES dbo.Parents (SchoolId, Id),
    CONSTRAINT CK_StudentParents_Relationship
        CHECK (Relationship IN ('Father', 'Mother', 'Guardian'))
);
GO
CREATE INDEX IX_StudentParents_School_Parent ON dbo.StudentParents (SchoolId, ParentId);
GO

/*------------------------------------------------------------------------------
  Subjects
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Subjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    SubjectName     NVARCHAR(100)                   NOT NULL,
    SubjectCode     NVARCHAR(20)                     NULL,
    Grade           NVARCHAR(10)                    NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Subjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Subjects_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Subjects_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Subjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Subjects_School_Code UNIQUE (SchoolId, SubjectCode),
    CONSTRAINT FK_Subjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO
CREATE UNIQUE INDEX UX_Subjects_School_Id ON dbo.Subjects (SchoolId, Id);
CREATE INDEX IX_Subjects_School_Grade     ON dbo.Subjects (SchoolId, Grade) INCLUDE (IsActive);
GO

/*------------------------------------------------------------------------------
  StudentSubjects -- NEW.

  sp_GetStudentProfileStats has always queried this table, but nothing ever
  created it, so the proc failed at runtime. sp_AssignSubjectsToStudent also
  had nowhere to write, which is why it silently returned 'Success' without
  saving anything.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.StudentSubjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    SubjectId       INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_StudentSubjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_StudentSubjects_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_StudentSubjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_StudentSubjects UNIQUE (SchoolId, StudentId, SubjectId),
    CONSTRAINT FK_StudentSubjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_StudentSubjects_Student
        FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_StudentSubjects_Subject
        FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id)
);
GO
CREATE INDEX IX_StudentSubjects_School_Subject ON dbo.StudentSubjects (SchoolId, SubjectId);
GO

/*------------------------------------------------------------------------------
  TeacherSubjects -- which subjects a teacher is qualified to teach.

  NOTE ON TeacherId SEMANTICS
    The old schema was inconsistent: TeacherSubjects.TeacherId referenced
    Teachers(Id) while TeacherSchedule.TeacherId and
    TeacherSubjectAssignments.TeacherId referenced Users(Id). Joins across
    them were therefore wrong.

    All three now reference Teachers(Id). Every procedure taking @TeacherId
    means Teachers.Id. Use sp_GetTeacherByUserId to translate a logged-in
    user's id. This is a deliberate breaking change -- see README.md.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSubjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSubjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSubjects_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSubjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_TeacherSubjects UNIQUE (SchoolId, TeacherId, SubjectId),
    CONSTRAINT FK_TeacherSubjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TeacherSubjects_Teacher
        FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TeacherSubjects_Subject
        FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id)
);
GO
CREATE INDEX IX_TeacherSubjects_School_Subject ON dbo.TeacherSubjects (SchoolId, SubjectId);
GO

/*------------------------------------------------------------------------------
  TeacherSubjectAssignments -- teacher teaches subject X to class Y.
  Drives which students a teacher may enter grades for.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSubjectAssignments (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    ClassId         INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSubjectAssignments_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSubjectAssignments_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSubjectAssignments PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_TeacherSubjectAssignments UNIQUE (SchoolId, TeacherId, SubjectId, ClassId),
    CONSTRAINT FK_TSA_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TSA_Teacher FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TSA_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT FK_TSA_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id)
);
GO
CREATE INDEX IX_TSA_School_Teacher ON dbo.TeacherSubjectAssignments (SchoolId, TeacherId) INCLUDE (IsActive);
CREATE INDEX IX_TSA_School_Class   ON dbo.TeacherSubjectAssignments (SchoolId, ClassId);
GO

/*------------------------------------------------------------------------------
  TeacherSchedule -- weekly timetable.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSchedule (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    ClassId         INT                             NOT NULL,
    DayOfWeek       INT                             NOT NULL,   -- 1=Monday .. 7=Sunday
    StartTime       TIME(0)                         NOT NULL,
    EndTime         TIME(0)                         NOT NULL,
    Room            NVARCHAR(50)                    NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSchedule_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSchedule_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSchedule_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSchedule PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_TeacherSchedule_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TeacherSchedule_Teacher FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TeacherSchedule_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT FK_TeacherSchedule_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT CK_TeacherSchedule_DayOfWeek CHECK (DayOfWeek BETWEEN 1 AND 7)
);
GO
CREATE INDEX IX_TeacherSchedule_School_Teacher_Day
    ON dbo.TeacherSchedule (SchoolId, TeacherId, DayOfWeek, StartTime) INCLUDE (IsActive);
CREATE INDEX IX_TeacherSchedule_School_Class_Day
    ON dbo.TeacherSchedule (SchoolId, ClassId, DayOfWeek, StartTime);
GO

/*==============================================================================
  SECTION 4 -- ATTENDANCE
==============================================================================*/

CREATE TABLE dbo.Attendance (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ClassId         INT                             NOT NULL,
    AttendanceDate  DATE                            NOT NULL,
    IsPresent       BIT                             NOT NULL,
    Remarks         NVARCHAR(255)                   NULL,
    MarkedBy        INT                             NOT NULL,   -- Users.Id
    MarkedAt        DATETIME                        NOT NULL
        CONSTRAINT DF_Attendance_MarkedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Attendance PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Attendance_Student_Date UNIQUE (SchoolId, StudentId, AttendanceDate),
    CONSTRAINT FK_Attendance_School   FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Attendance_Student  FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_Attendance_Class    FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT FK_Attendance_MarkedBy FOREIGN KEY (SchoolId, MarkedBy)  REFERENCES dbo.Users    (SchoolId, Id)
);
GO
CREATE INDEX IX_Attendance_School_Class_Date
    ON dbo.Attendance (SchoolId, ClassId, AttendanceDate) INCLUDE (IsPresent, StudentId);
CREATE INDEX IX_Attendance_School_Date
    ON dbo.Attendance (SchoolId, AttendanceDate) INCLUDE (IsPresent);
GO

/*==============================================================================
  SECTION 5 -- EXAMINATIONS AND RESULTS
==============================================================================*/

CREATE TABLE dbo.Examinations (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    ExamName        NVARCHAR(100)                   NOT NULL,
    ExamType        NVARCHAR(50)                    NOT NULL,
    ClassId         INT                             NOT NULL,
    SubjectId       INT                             NOT NULL,
    ExamDate        DATE                            NOT NULL,
    MaxMarks        INT                             NOT NULL,
    PassingMarks    INT                             NOT NULL,
    Duration        INT                             NULL,   -- minutes
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Examinations_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Examinations_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Examinations_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Examinations PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_Examinations_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Examinations_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT FK_Examinations_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT CK_Examinations_Marks CHECK (MaxMarks > 0 AND PassingMarks >= 0 AND PassingMarks <= MaxMarks)
);
GO
CREATE UNIQUE INDEX UX_Examinations_School_Id ON dbo.Examinations (SchoolId, Id);
CREATE INDEX IX_Examinations_School_Class_Subject
    ON dbo.Examinations (SchoolId, ClassId, SubjectId) INCLUDE (IsActive, ExamDate);
GO

CREATE TABLE dbo.Results (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ExaminationId   INT                             NOT NULL,
    ObtainedMarks   INT                             NOT NULL,
    Grade           NVARCHAR(5)                     NULL,
    Remarks         NVARCHAR(255)                   NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Results_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Results_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Results_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Results PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Results_Student_Exam UNIQUE (SchoolId, StudentId, ExaminationId),
    CONSTRAINT FK_Results_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Results_Student FOREIGN KEY (SchoolId, StudentId)     REFERENCES dbo.Students     (SchoolId, Id),
    CONSTRAINT FK_Results_Exam    FOREIGN KEY (SchoolId, ExaminationId) REFERENCES dbo.Examinations (SchoolId, Id),
    CONSTRAINT CK_Results_ObtainedMarks CHECK (ObtainedMarks >= 0)
);
GO
CREATE INDEX IX_Results_School_Exam ON dbo.Results (SchoolId, ExaminationId) INCLUDE (StudentId, ObtainedMarks);
GO

/*==============================================================================
  SECTION 6 -- FEES
==============================================================================*/

/* Fee types used to be a single global list. They are now per school, so each
   school can price and name its own. sp_CreateSchool seeds the standard seven. */
CREATE TABLE dbo.FeeTypes (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    FeeTypeName     NVARCHAR(100)                   NOT NULL,
    Description     NVARCHAR(255)                   NULL,
    DefaultAmount   DECIMAL(10,2)                   NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_FeeTypes_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_FeeTypes_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_FeeTypes_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_FeeTypes PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_FeeTypes_School_Name UNIQUE (SchoolId, FeeTypeName),
    CONSTRAINT FK_FeeTypes_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO
CREATE UNIQUE INDEX UX_FeeTypes_School_Id ON dbo.FeeTypes (SchoolId, Id);
GO

CREATE TABLE dbo.Fees (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    FeeTypeId       INT                             NOT NULL,
    Amount          DECIMAL(10,2)                   NOT NULL,
    DueDate         DATE                            NOT NULL,
    FeeMonth        INT                             NOT NULL,
    FeeYear         INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Fees_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Fees_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Fees_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Fees PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_Fees_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Fees_Student FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_Fees_FeeType FOREIGN KEY (SchoolId, FeeTypeId) REFERENCES dbo.FeeTypes (SchoolId, Id),
    CONSTRAINT CK_Fees_Amount CHECK (Amount >= 0),
    CONSTRAINT CK_Fees_FeeMonth CHECK (FeeMonth BETWEEN 1 AND 12),
    CONSTRAINT CK_Fees_FeeYear CHECK (FeeYear BETWEEN 2000 AND 2200)
);
GO
CREATE UNIQUE INDEX UX_Fees_School_Id ON dbo.Fees (SchoolId, Id);
CREATE INDEX IX_Fees_School_Student   ON dbo.Fees (SchoolId, StudentId) INCLUDE (IsActive, Amount, DueDate);
CREATE INDEX IX_Fees_School_DueDate   ON dbo.Fees (SchoolId, DueDate)   INCLUDE (IsActive, Amount, StudentId);
GO

/* One fee row per student / type / period. Stops the same monthly fee being
   raised twice, which the old schema allowed. */
CREATE UNIQUE INDEX UX_Fees_School_Student_Type_Period
    ON dbo.Fees (SchoolId, StudentId, FeeTypeId, FeeYear, FeeMonth);
GO

CREATE TABLE dbo.FeePayments (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    FeeId           INT                             NOT NULL,
    ReceiptNumber   NVARCHAR(40)                    NULL,
    AmountPaid      DECIMAL(10,2)                   NOT NULL,
    PaymentDate     DATE                            NOT NULL,
    PaymentMethod   NVARCHAR(50)                    NOT NULL,
    TransactionId   NVARCHAR(100)                   NULL,
    PaymentStatus   NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_FeePayments_PaymentStatus DEFAULT ('Completed'),
    Remarks         NVARCHAR(255)                   NULL,
    PaidBy          INT                             NOT NULL,   -- Users.Id
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_FeePayments_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_FeePayments PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_FeePayments_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_FeePayments_Fee    FOREIGN KEY (SchoolId, FeeId)  REFERENCES dbo.Fees  (SchoolId, Id),
    CONSTRAINT FK_FeePayments_PaidBy FOREIGN KEY (SchoolId, PaidBy) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT CK_FeePayments_AmountPaid CHECK (AmountPaid > 0),
    CONSTRAINT CK_FeePayments_PaymentStatus
        CHECK (PaymentStatus IN ('Completed', 'Pending', 'Failed', 'Refunded'))
);
GO
CREATE INDEX IX_FeePayments_School_Fee ON dbo.FeePayments (SchoolId, FeeId) INCLUDE (AmountPaid, PaymentStatus);
GO
CREATE UNIQUE INDEX UX_FeePayments_School_Receipt
    ON dbo.FeePayments (SchoolId, ReceiptNumber)
    WHERE ReceiptNumber IS NOT NULL;
GO

/*==============================================================================
  SECTION 7 -- CONFIGURATION, TOKENS, AUDIT
==============================================================================*/

/* Settings are per school: (SchoolId, Category, SettingKey) is the key.
   sp_CreateSchool seeds the full default set for each new school. */
CREATE TABLE dbo.Settings (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    Category        NVARCHAR(50)                    NOT NULL,
    SettingKey      NVARCHAR(100)                   NOT NULL,
    SettingValue    NVARCHAR(MAX)                   NOT NULL,
    DataType        NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_Settings_DataType DEFAULT ('string'),
    Description     NVARCHAR(255)                   NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Settings_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Settings_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Settings_UpdatedAt DEFAULT (GETDATE()),
    CreatedBy       INT                             NULL,
    UpdatedBy       INT                             NULL,

    CONSTRAINT PK_Settings PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Settings_School_Category_Key UNIQUE (SchoolId, Category, SettingKey),
    CONSTRAINT FK_Settings_School    FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Settings_CreatedBy FOREIGN KEY (SchoolId, CreatedBy) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT FK_Settings_UpdatedBy FOREIGN KEY (SchoolId, UpdatedBy) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT CK_Settings_DataType CHECK (DataType IN ('string', 'number', 'boolean', 'json'))
);
GO
CREATE INDEX IX_Settings_School_Category ON dbo.Settings (SchoolId, Category) INCLUDE (SettingKey, SettingValue);
GO

/* RefreshTokens has no SchoolId: it is scoped through UserId, and a token is
   never queried without one. ExpiryDate is stored in UTC -- see the header. */
CREATE TABLE dbo.RefreshTokens (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    UserId          INT                             NOT NULL,
    Token           NVARCHAR(255)                   NOT NULL,
    ExpiryDate      DATETIME                        NOT NULL,   -- UTC
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_RefreshTokens_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_RefreshTokens_CreatedAt DEFAULT (GETUTCDATE()),
    RevokedAt       DATETIME                        NULL,
    RevokedByIp     NVARCHAR(50)                    NULL,
    ReplacedByToken NVARCHAR(255)                   NULL,

    CONSTRAINT PK_RefreshTokens PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_RefreshTokens_Token UNIQUE (Token),
    CONSTRAINT FK_RefreshTokens_User FOREIGN KEY (UserId) REFERENCES dbo.Users (Id)
);
GO
CREATE INDEX IX_RefreshTokens_UserId     ON dbo.RefreshTokens (UserId) INCLUDE (IsActive, ExpiryDate);
CREATE INDEX IX_RefreshTokens_ExpiryDate ON dbo.RefreshTokens (ExpiryDate);
GO

/*------------------------------------------------------------------------------
  AuditLog -- NEW.

  sp_GetUserActivityLog and sp_GetProfileActivities previously stitched an
  activity feed together out of CreatedAt columns because there was no audit
  table. They now read real events from here.

  SchoolId is nullable: platform-level actions (creating a school) have no
  tenant. That is also why the FK is single-column rather than composite.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.AuditLog (
    Id              BIGINT          IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NULL,
    UserId          INT                             NULL,
    Action          NVARCHAR(100)                   NOT NULL,
    EntityType      NVARCHAR(50)                    NULL,
    EntityId        INT                             NULL,
    Details         NVARCHAR(1000)                  NULL,
    IpAddress       NVARCHAR(50)                    NULL,
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_AuditLog_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_AuditLog_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_AuditLog_User   FOREIGN KEY (UserId)   REFERENCES dbo.Users (Id)
);
GO
CREATE INDEX IX_AuditLog_School_Created ON dbo.AuditLog (SchoolId, CreatedAt DESC);
CREATE INDEX IX_AuditLog_User_Created   ON dbo.AuditLog (UserId, CreatedAt DESC);
GO

/*==============================================================================
  SECTION 8 -- COMPATIBILITY VIEW

  vw_Users presents a User, their Person and their primary Address as one flat
  row, using the exact column names Users had before the split. Every read-only
  procedure in 04..14 selects "FROM dbo.vw_Users AS u" where it used to say
  "FROM dbo.Users AS u", so no result-set column name changed and no DTO or React
  table had to be touched.

  READ ONLY. Do not write through this view -- INSERT/UPDATE against a multi-table
  view either fails or silently touches one table. Writers go to Users, Persons
  and Addresses directly, or through sp_UpsertPerson / sp_UpsertAddress.

  WHICH ADDRESS
    The primary one; failing that, the lowest-numbered active one. Deterministic
    because UX_Addresses_Person_Primary allows at most one primary per person.

  THE Address COLUMN
    Assembled from the parts with ', ' separators, skipping the NULLs. A row
    written from the old single-string API (everything in AddressLine1) therefore
    reads back byte-identical.
==============================================================================*/
CREATE VIEW dbo.vw_Users
AS
SELECT u.Id,
       u.SchoolId,
       u.PersonId,
       u.Username,
       u.Email,
       u.PasswordHash,
       p.FirstName,
       p.LastName,
       p.FirstName + N' ' + p.LastName        AS FullName,
       p.PhoneNumber,
       p.AlternatePhoneNumber,
       u.RoleId,
       r.RoleName                             AS Role,
       r.RoleCode,
       u.IsActive,
       u.RequirePasswordChange,
       p.ProfilePicture,
       p.ProfilePictureFileName,
       p.ProfilePictureContentType,
       p.ProfilePictureUploadDate,
       a.Id                                   AS AddressId,
       a.AddressType,
       a.AddressLine1,
       a.AddressLine2,
       a.Landmark,
       a.City,
       a.State,
       a.Country,
       a.PostalCode,
       /* STUFF drops the leading ', '; it returns NULL for an empty string, which
          is exactly right for a person with no address at all. */
       STUFF(ISNULL(N', ' + a.AddressLine1, N'')
           + ISNULL(N', ' + a.AddressLine2, N'')
           + ISNULL(N', ' + a.Landmark,     N'')
           + ISNULL(N', ' + a.City,         N'')
           + ISNULL(N', ' + a.State,        N'')
           + ISNULL(N', ' + a.PostalCode,   N'')
           + ISNULL(N', ' + a.Country,      N''),
             1, 2, N'')                       AS Address,
       u.LastLoginAt,
       u.CreatedBy,
       u.ModifiedBy,
       cb.Username                            AS CreatedByUsername,
       mb.Username                            AS ModifiedByUsername,
       u.CreatedAt,
       u.UpdatedAt
FROM dbo.Users AS u
INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
INNER JOIN dbo.Roles   AS r ON r.Id = u.RoleId
LEFT  JOIN dbo.Users   AS cb ON cb.Id = u.CreatedBy
LEFT  JOIN dbo.Users   AS mb ON mb.Id = u.ModifiedBy
OUTER APPLY (
    SELECT TOP (1) ad.*
    FROM dbo.Addresses AS ad
    WHERE ad.PersonId = u.PersonId
      AND ad.IsActive = 1
    ORDER BY ad.IsPrimary DESC, ad.Id
) AS a;
GO

PRINT '=== 01_Schema.sql complete ===';
GO

SET NOEXEC OFF;
GO
