/*==============================================================================
  Table : dbo.Subjects
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
  Subjects
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Subjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    SubjectName     NVARCHAR(100)                   NOT NULL,
    SubjectCode     NVARCHAR(20)                     NULL,
    Grade           NVARCHAR(10)                    NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Subjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Subjects_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Subjects_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Subjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Subjects_School_Code UNIQUE (SchoolId, SubjectCode),
    CONSTRAINT FK_Subjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO
CREATE UNIQUE INDEX UX_Subjects_School_Id ON dbo.Subjects (SchoolId, Id);
CREATE INDEX IX_Subjects_School_Grade     ON dbo.Subjects (SchoolId, Grade) INCLUDE (IsActive);
GO

SET NOEXEC OFF;
GO

