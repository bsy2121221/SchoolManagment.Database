/*==============================================================================
  Table : dbo.FeeTypes
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

SET NOEXEC OFF;
GO

