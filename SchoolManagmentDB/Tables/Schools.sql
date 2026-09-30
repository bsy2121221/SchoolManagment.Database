/*==============================================================================
  Table : dbo.Schools
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
  Schools -- the tenant registry. The only table without a SchoolId.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.Schools (
    Id                      INT             IDENTITY(1,1)   NOT NULL,
    SchoolCode              NVARCHAR(12)                    NOT NULL,
    SchoolName              NVARCHAR(150)                   NOT NULL,
    Subdomain               NVARCHAR(63)                    NULL,
    Address                 NVARCHAR(255)                   NULL,
    City                    NVARCHAR(80)                    NULL,
    State                   NVARCHAR(80)                    NULL,
    Country                 NVARCHAR(80)                    NULL,
    PostalCode              NVARCHAR(20)                    NULL,
    ContactEmail            NVARCHAR(100)                   NULL,
    ContactPhone            NVARCHAR(20)                    NULL,
    PrincipalName           NVARCHAR(100)                   NULL,
    LogoUrl                 NVARCHAR(500)                   NULL,
    ThemeColor              NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_Schools_ThemeColor DEFAULT ('#1976d2'),
    AcademicYearStartMonth  TINYINT                         NOT NULL
        CONSTRAINT DF_Schools_AcademicYearStartMonth DEFAULT (4),
    IsActive                BIT                             NOT NULL
        CONSTRAINT DF_Schools_IsActive DEFAULT (1),
    CreatedAt               DATETIME                        NOT NULL
        CONSTRAINT DF_Schools_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt               DATETIME                        NOT NULL
        CONSTRAINT DF_Schools_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Schools PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Schools_SchoolCode UNIQUE (SchoolCode),

    /* SchoolCode is embedded verbatim into usernames and student IDs, so it
       must be A-Z0-9 only. The BIN collation matters: under the default
       case-insensitive collation, '[^A-Z0-9]' would happily accept lowercase. */
    CONSTRAINT CK_Schools_SchoolCode CHECK (
        LEN(SchoolCode) BETWEEN 3 AND 12
        AND SchoolCode COLLATE Latin1_General_BIN NOT LIKE '%[^A-Z0-9]%'
    ),
    CONSTRAINT CK_Schools_Subdomain CHECK (
        Subdomain IS NULL
        OR (LEN(Subdomain) BETWEEN 2 AND 63
            AND Subdomain COLLATE Latin1_General_BIN NOT LIKE '%[^a-z0-9-]%'
            AND Subdomain NOT LIKE '-%'
            AND Subdomain NOT LIKE '%-')
    ),
    CONSTRAINT CK_Schools_AcademicYearStartMonth CHECK (AcademicYearStartMonth BETWEEN 1 AND 12)
);
GO

/* Filtered, because Subdomain is optional and many schools may have none. */
CREATE UNIQUE INDEX UX_Schools_Subdomain
    ON dbo.Schools (Subdomain)
    WHERE Subdomain IS NOT NULL;
GO

SET NOEXEC OFF;
GO

