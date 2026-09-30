/*==============================================================================
  Table : dbo.AuditLog
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
  AuditLog -- NEW.

  sp_GetUserActivityLog and sp_GetProfileActivities previously stitched an
  activity feed together out of CreatedAt columns because there was no audit
  table. They now read real events from here.

  SchoolId is nullable: platform-level actions (creating a school) have no
  tenant. That is also why the FK is single-column rather than composite.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.AuditLog (
    Id              BIGINT          IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NULL,
    UserId          INT                             NULL,
    Action          NVARCHAR(100)                   NOT NULL,
    EntityType      NVARCHAR(50)                    NULL,
    EntityId        INT                             NULL,
    Details         NVARCHAR(1000)                  NULL,
    IpAddress       NVARCHAR(50)                    NULL,
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_AuditLog_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_AuditLog PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_AuditLog_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_AuditLog_User   FOREIGN KEY (UserId)   REFERENCES dbo.Users (Id)
);
GO
CREATE INDEX IX_AuditLog_School_Created ON dbo.AuditLog (SchoolId, CreatedAt DESC);
CREATE INDEX IX_AuditLog_User_Created   ON dbo.AuditLog (UserId, CreatedAt DESC);
GO

/*==============================================================================
  SECTION 8 -- COMPATIBILITY VIEW

  vw_Users presents a User, their Person and their primary Address as one flat
  row, using the exact column names Users had before the split. Every read-only
  procedure in 04..14 selects "FROM dbo.vw_Users AS u" where it used to say
  "FROM dbo.Users AS u", so no result-set column name changed and no DTO or React
  table had to be touched.

  READ ONLY. Do not write through this view -- INSERT/UPDATE against a multi-table
  view either fails or silently touches one table. Writers go to Users, Persons
  and Addresses directly, or through sp_UpsertPerson / sp_UpsertAddress.

  WHICH ADDRESS
    The primary one; failing that, the lowest-numbered active one. Deterministic
    because UX_Addresses_Person_Primary allows at most one primary per person.

  THE Address COLUMN
    Assembled from the parts with ', ' separators, skipping the NULLs. A row
    written from the old single-string API (everything in AddressLine1) therefore
    reads back byte-identical.
==============================================================================*/

SET NOEXEC OFF;
GO

