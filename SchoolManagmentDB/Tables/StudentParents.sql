/*==============================================================================
  Table : dbo.StudentParents
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
  StudentParents -- many-to-many
------------------------------------------------------------------------------*/
CREATE TABLE dbo.StudentParents (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ParentId        INT                             NOT NULL,   -- Parents.Id
    Relationship    NVARCHAR(20)                    NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_StudentParents_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_StudentParents_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_StudentParents PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_StudentParents UNIQUE (SchoolId, StudentId, ParentId),
    CONSTRAINT FK_StudentParents_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_StudentParents_Student
        FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_StudentParents_Parent
        FOREIGN KEY (SchoolId, ParentId) REFERENCES dbo.Parents (SchoolId, Id),
    CONSTRAINT CK_StudentParents_Relationship
        CHECK (Relationship IN ('Father', 'Mother', 'Guardian'))
);
GO
CREATE INDEX IX_StudentParents_School_Parent ON dbo.StudentParents (SchoolId, ParentId);
GO

SET NOEXEC OFF;
GO

