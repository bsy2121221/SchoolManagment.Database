/*==============================================================================
  Table : dbo.Settings
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

SET NOEXEC OFF;
GO

