/*==============================================================================
  Table : dbo.Persons
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

SET NOEXEC OFF;
GO

