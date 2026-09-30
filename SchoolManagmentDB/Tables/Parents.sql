/*==============================================================================
  Table : dbo.Parents
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

SET NOEXEC OFF;
GO

