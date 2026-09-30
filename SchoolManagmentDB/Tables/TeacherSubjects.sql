/*==============================================================================
  Table : dbo.TeacherSubjects
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
  TeacherSubjects -- which subjects a teacher is qualified to teach.

  NOTE ON TeacherId SEMANTICS
    The old schema was inconsistent: TeacherSubjects.TeacherId referenced
    Teachers(Id) while TeacherSchedule.TeacherId and
    TeacherSubjectAssignments.TeacherId referenced Users(Id). Joins across
    them were therefore wrong.

    All three now reference Teachers(Id). Every procedure taking @TeacherId
    means Teachers.Id. Use sp_GetTeacherByUserId to translate a logged-in
    user's id. This is a deliberate breaking change -- see README.md.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSubjects (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSubjects_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSubjects_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSubjects PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_TeacherSubjects UNIQUE (SchoolId, TeacherId, SubjectId),
    CONSTRAINT FK_TeacherSubjects_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TeacherSubjects_Teacher
        FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TeacherSubjects_Subject
        FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id)
);
GO
CREATE INDEX IX_TeacherSubjects_School_Subject ON dbo.TeacherSubjects (SchoolId, SubjectId);
GO

SET NOEXEC OFF;
GO

