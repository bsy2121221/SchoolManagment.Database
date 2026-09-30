/*==============================================================================
  Table : dbo.Teachers
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

SET NOEXEC OFF;
GO

