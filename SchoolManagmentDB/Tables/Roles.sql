/*==============================================================================
  Table : dbo.Roles
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

SET NOEXEC OFF;
GO

