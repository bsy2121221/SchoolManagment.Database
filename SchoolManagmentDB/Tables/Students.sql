/*==============================================================================
  Table : dbo.Students
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
  Students
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Students (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    UserId          INT                             NOT NULL,
    StudentId       NVARCHAR(40)                    NOT NULL,   -- human-readable admission number
    ClassId         INT                             NULL,
    RollNumber      NVARCHAR(10)                    NULL,
    DateOfBirth     DATE                            NULL,
    Gender          NVARCHAR(10)                    NULL,
    FatherName      NVARCHAR(100)                   NULL,
    MotherName      NVARCHAR(100)                   NULL,
    AdmissionDate   DATE                            NOT NULL
        CONSTRAINT DF_Students_AdmissionDate DEFAULT (GETDATE()),
    BloodGroup      NVARCHAR(5)                     NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Students_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Students_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Students_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Students PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Students_UserId UNIQUE (UserId),
    CONSTRAINT UQ_Students_School_StudentId UNIQUE (SchoolId, StudentId),
    CONSTRAINT FK_Students_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Students_User FOREIGN KEY (SchoolId, UserId) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT FK_Students_Class FOREIGN KEY (SchoolId, ClassId) REFERENCES dbo.Classes (SchoolId, Id),
    CONSTRAINT CK_Students_Gender CHECK (Gender IS NULL OR Gender IN ('Male', 'Female', 'Other'))
);
GO
CREATE UNIQUE INDEX UX_Students_School_Id  ON dbo.Students (SchoolId, Id);
CREATE INDEX IX_Students_School_Class      ON dbo.Students (SchoolId, ClassId) INCLUDE (IsActive, RollNumber);
CREATE INDEX IX_Students_School_StudentId  ON dbo.Students (SchoolId, StudentId);
GO

/* Roll numbers are unique within a class, but only where one is assigned. */
CREATE UNIQUE INDEX UX_Students_School_Class_Roll
    ON dbo.Students (SchoolId, ClassId, RollNumber)
    WHERE ClassId IS NOT NULL AND RollNumber IS NOT NULL;
GO

SET NOEXEC OFF;
GO

