/*==============================================================================
  Table : dbo.Examinations
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
CREATE TABLE dbo.Examinations (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    ExamName        NVARCHAR(100)                   NOT NULL,
    ExamType        NVARCHAR(50)                    NOT NULL,
    ClassId         INT                             NOT NULL,
    SubjectId       INT                             NOT NULL,
    ExamDate        DATE                            NOT NULL,
    MaxMarks        INT                             NOT NULL,
    PassingMarks    INT                             NOT NULL,
    Duration        INT                             NULL,   -- minutes
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Examinations_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Examinations_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Examinations_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Examinations PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_Examinations_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Examinations_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT FK_Examinations_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT CK_Examinations_Marks CHECK (MaxMarks > 0 AND PassingMarks >= 0 AND PassingMarks <= MaxMarks)
);
GO
CREATE UNIQUE INDEX UX_Examinations_School_Id ON dbo.Examinations (SchoolId, Id);
CREATE INDEX IX_Examinations_School_Class_Subject
    ON dbo.Examinations (SchoolId, ClassId, SubjectId) INCLUDE (IsActive, ExamDate);
GO

SET NOEXEC OFF;
GO

