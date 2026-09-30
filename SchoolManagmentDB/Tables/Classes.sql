/*==============================================================================
  Table : dbo.Classes
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
  Classes
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Classes (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    ClassName       NVARCHAR(50)                    NOT NULL,
    Grade           NVARCHAR(10)                    NOT NULL,
    Section         NVARCHAR(5)                     NOT NULL,
    ClassTeacherId  INT                             NULL,   -- Teachers.Id
    MaxStudents     INT                             NOT NULL
        CONSTRAINT DF_Classes_MaxStudents DEFAULT (50),
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Classes_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Classes_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Classes_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Classes PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Classes_School_ClassName UNIQUE (SchoolId, ClassName),
    CONSTRAINT UQ_Classes_School_GradeSection UNIQUE (SchoolId, Grade, Section),
    CONSTRAINT FK_Classes_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Classes_ClassTeacher
        FOREIGN KEY (SchoolId, ClassTeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT CK_Classes_MaxStudents CHECK (MaxStudents > 0)
);
GO
CREATE UNIQUE INDEX UX_Classes_School_Id ON dbo.Classes (SchoolId, Id);
CREATE INDEX IX_Classes_School_IsActive  ON dbo.Classes (SchoolId, IsActive);
GO

SET NOEXEC OFF;
GO

