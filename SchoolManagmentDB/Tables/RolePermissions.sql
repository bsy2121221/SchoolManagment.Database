/*==============================================================================
  Table : dbo.RolePermissions
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

SET NOEXEC OFF;
GO

