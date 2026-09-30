/*==============================================================================
  Table : dbo.SchoolSequences
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
  SchoolSequences -- per-school counters.

  Replaces the old "(SELECT COUNT(*) + 1 FROM Students WHERE ClassId = @x)"
  pattern, which handed the same number to two concurrent registrations and
  re-used numbers after a delete.

  SequenceName values in use:
      'Student'          admission serial, per school
      'Employee'         employee serial, per school
      'Receipt'          fee receipt serial, per school
      'Roll:<ClassId>'   roll number, per school + class
------------------------------------------------------------------------------*/
CREATE TABLE dbo.SchoolSequences (
    SchoolId        INT             NOT NULL,
    SequenceName    NVARCHAR(50)    NOT NULL,
    LastValue       INT             NOT NULL
        CONSTRAINT DF_SchoolSequences_LastValue DEFAULT (0),
    UpdatedAt       DATETIME        NOT NULL
        CONSTRAINT DF_SchoolSequences_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_SchoolSequences PRIMARY KEY CLUSTERED (SchoolId, SequenceName),
    CONSTRAINT FK_SchoolSequences_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id)
);
GO

/*==============================================================================
  SECTION 2 -- IDENTITY

  The identity of a human is split across three tables:

      Persons     who they are        FirstName, LastName, phone, photo
      Users       how they log in     Username, Email, PasswordHash, RoleId
      Addresses   where they live     one or more typed postal addresses

  Users holds NOTHING but account/credential data. Anything descriptive lives on
  the Persons row it points at. That is what lets a person keep one identity
  while their login is disabled, renamed, or re-roled.

  Roles / RolePermissions replace the old Users.Role NVARCHAR column.

  READING THE OLD SHAPE
    dbo.vw_Users (bottom of this file) re-joins the three tables and exposes the
    flat pre-split column list -- FirstName, LastName, PhoneNumber, Address,
    Role. Every read-only procedure selects from the view, so result-set column
    names did not change. Only procedures that WRITE were rewritten.
==============================================================================*/

SET NOEXEC OFF;
GO

