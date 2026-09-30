/*==============================================================================
  Table : dbo.Users
  Extracted from: 01_Schema.sql
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

SET NOEXEC OFF;
GO

