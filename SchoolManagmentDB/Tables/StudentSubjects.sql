/*==============================================================================
  Table : dbo.StudentSubjects
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
  StudentSubjects -- NEW.

  sp_GetStudentProfileStats has always queried this table, but nothing ever
  created it, so the proc failed at runtime. sp_AssignSubjectsToStudent also
  had nowhere to write, which is why it silently returned 'Success' without
  saving anything.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.StudentSubjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    SubjectId       INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_StudentSubjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_StudentSubjects_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_StudentSubjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_StudentSubjects UNIQUE (SchoolId, StudentId, SubjectId),
    CONSTRAINT FK_StudentSubjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_StudentSubjects_Student
        FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_StudentSubjects_Subject
        FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id)
);
GO
CREATE INDEX IX_StudentSubjects_School_Subject ON dbo.StudentSubjects (SchoolId, SubjectId);
GO

SET NOEXEC OFF;
GO

