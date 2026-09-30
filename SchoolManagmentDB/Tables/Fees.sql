/*==============================================================================
  Table : dbo.Fees
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
CREATE TABLE dbo.Fees (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    FeeTypeId       INT                             NOT NULL,
    Amount          DECIMAL(10,2)                   NOT NULL,
    DueDate         DATE                            NOT NULL,
    FeeMonth        INT                             NOT NULL,
    FeeYear         INT                             NOT NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_Fees_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Fees_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_Fees_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Fees PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_Fees_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Fees_Student FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_Fees_FeeType FOREIGN KEY (SchoolId, FeeTypeId) REFERENCES dbo.FeeTypes (SchoolId, Id),
    CONSTRAINT CK_Fees_Amount CHECK (Amount >= 0),
    CONSTRAINT CK_Fees_FeeMonth CHECK (FeeMonth BETWEEN 1 AND 12),
    CONSTRAINT CK_Fees_FeeYear CHECK (FeeYear BETWEEN 2000 AND 2200)
);
GO
CREATE UNIQUE INDEX UX_Fees_School_Id ON dbo.Fees (SchoolId, Id);
CREATE INDEX IX_Fees_School_Student   ON dbo.Fees (SchoolId, StudentId) INCLUDE (IsActive, Amount, DueDate);
CREATE INDEX IX_Fees_School_DueDate   ON dbo.Fees (SchoolId, DueDate)   INCLUDE (IsActive, Amount, StudentId);
GO

/* One fee row per student / type / period. Stops the same monthly fee being
   raised twice, which the old schema allowed. */
CREATE UNIQUE INDEX UX_Fees_School_Student_Type_Period
    ON dbo.Fees (SchoolId, StudentId, FeeTypeId, FeeYear, FeeMonth);
GO

SET NOEXEC OFF;
GO

