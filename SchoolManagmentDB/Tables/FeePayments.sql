/*==============================================================================
  Table : dbo.FeePayments
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
CREATE TABLE dbo.FeePayments (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    FeeId           INT                             NOT NULL,
    ReceiptNumber   NVARCHAR(40)                    NULL,
    AmountPaid      DECIMAL(10,2)                   NOT NULL,
    PaymentDate     DATE                            NOT NULL,
    PaymentMethod   NVARCHAR(50)                    NOT NULL,
    TransactionId   NVARCHAR(100)                   NULL,
    PaymentStatus   NVARCHAR(20)                    NOT NULL
        CONSTRAINT DF_FeePayments_PaymentStatus DEFAULT ('Completed'),
    Remarks         NVARCHAR(255)                   NULL,
    PaidBy          INT                             NOT NULL,   -- Users.Id
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_FeePayments_CreatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_FeePayments PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_FeePayments_School FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_FeePayments_Fee    FOREIGN KEY (SchoolId, FeeId)  REFERENCES dbo.Fees  (SchoolId, Id),
    CONSTRAINT FK_FeePayments_PaidBy FOREIGN KEY (SchoolId, PaidBy) REFERENCES dbo.Users (SchoolId, Id),
    CONSTRAINT CK_FeePayments_AmountPaid CHECK (AmountPaid > 0),
    CONSTRAINT CK_FeePayments_PaymentStatus
        CHECK (PaymentStatus IN ('Completed', 'Pending', 'Failed', 'Refunded'))
);
GO
CREATE INDEX IX_FeePayments_School_Fee ON dbo.FeePayments (SchoolId, FeeId) INCLUDE (AmountPaid, PaymentStatus);
GO
CREATE UNIQUE INDEX UX_FeePayments_School_Receipt
    ON dbo.FeePayments (SchoolId, ReceiptNumber)
    WHERE ReceiptNumber IS NOT NULL;
GO

/*==============================================================================
  SECTION 7 -- CONFIGURATION, TOKENS, AUDIT
==============================================================================*/

/* Settings are per school: (SchoolId, Category, SettingKey) is the key.
   sp_CreateSchool seeds the full default set for each new school. */

SET NOEXEC OFF;
GO

