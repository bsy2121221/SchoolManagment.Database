/*==============================================================================
  Table : dbo.TeacherSubjectAssignments
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
  TeacherSubjectAssignments -- teacher teaches subject X to class Y.
  Drives which students a teacher may enter grades for.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSubjectAssignments (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    ClassId         INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSubjectAssignments_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSubjectAssignments_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSubjectAssignments PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_TeacherSubjectAssignments UNIQUE (SchoolId, TeacherId, SubjectId, ClassId),
    CONSTRAINT FK_TSA_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TSA_Teacher FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TSA_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT FK_TSA_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id)
);
GO
CREATE INDEX IX_TSA_School_Teacher ON dbo.TeacherSubjectAssignments (SchoolId, TeacherId) INCLUDE (IsActive);
CREATE INDEX IX_TSA_School_Class   ON dbo.TeacherSubjectAssignments (SchoolId, ClassId);
GO

SET NOEXEC OFF;
GO

