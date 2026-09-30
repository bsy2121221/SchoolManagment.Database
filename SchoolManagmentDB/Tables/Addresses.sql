/*==============================================================================
  Table : dbo.Addresses
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

SET NOEXEC OFF;
GO