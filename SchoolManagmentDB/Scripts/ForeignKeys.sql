/*==============================================================================
  Scripts/ForeignKeys.sql
  ------------------------------------------------------------------------------
  Deferred audit FKs that could not be declared inline on CREATE TABLE.

  Roles, RolePermissions, Persons and Addresses are created before Users
  (Users points at Roles and Persons), so their CreatedBy / ModifiedBy columns
  get foreign keys here — after Users exists.

  All other FKs (including composite tenant FKs) live inline in Tables/*.sql.
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

PRINT '=== ForeignKeys.sql complete ===';
GO

SET NOEXEC OFF;
GO