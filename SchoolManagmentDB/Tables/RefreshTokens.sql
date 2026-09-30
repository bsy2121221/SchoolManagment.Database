/*==============================================================================
  Table : dbo.RefreshTokens
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
CREATE TABLE dbo.RefreshTokens (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    UserId          INT                             NOT NULL,
    Token           NVARCHAR(255)                   NOT NULL,
    ExpiryDate      DATETIME                        NOT NULL,   -- UTC
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_RefreshTokens_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_RefreshTokens_CreatedAt DEFAULT (GETUTCDATE()),
    RevokedAt       DATETIME                        NULL,
    RevokedByIp     NVARCHAR(50)                    NULL,
    ReplacedByToken NVARCHAR(255)                   NULL,

    CONSTRAINT PK_RefreshTokens PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_RefreshTokens_Token UNIQUE (Token),
    CONSTRAINT FK_RefreshTokens_User FOREIGN KEY (UserId) REFERENCES dbo.Users (Id)
);
GO
CREATE INDEX IX_RefreshTokens_UserId     ON dbo.RefreshTokens (UserId) INCLUDE (IsActive, ExpiryDate);
CREATE INDEX IX_RefreshTokens_ExpiryDate ON dbo.RefreshTokens (ExpiryDate);
GO

SET NOEXEC OFF;
GO

