/*==============================================================================
  Table : dbo.Results
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
CREATE TABLE dbo.Results (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ExaminationId   INT                             NOT NULL,
    ObtainedMarks   INT                             NOT NULL,
    Grade           NVARCHAR(5)                     NULL,
    Remarks         NVARCHAR(255)                   NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Results_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Results_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Results_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Results PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Results_Student_Exam UNIQUE (SchoolId, StudentId, ExaminationId),
    CONSTRAINT FK_Results_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Results_Student FOREIGN KEY (SchoolId, StudentId)     REFERENCES dbo.Students     (SchoolId, Id),
    CONSTRAINT FK_Results_Exam    FOREIGN KEY (SchoolId, ExaminationId) REFERENCES dbo.Examinations (SchoolId, Id),
    CONSTRAINT CK_Results_ObtainedMarks CHECK (ObtainedMarks >= 0)
);
GO
CREATE INDEX IX_Results_School_Exam ON dbo.Results (SchoolId, ExaminationId) INCLUDE (StudentId, ObtainedMarks);
GO

/*==============================================================================
  SECTION 6 -- FEES
==============================================================================*/

/* Fee types used to be a single global list. They are now per school, so each
   school can price and name its own. sp_CreateSchool seeds the standard seven. */

SET NOEXEC OFF;
GO

