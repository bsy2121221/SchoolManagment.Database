/*==============================================================================
  StoredProcedure : dbo.sp_UpsertAddress
  Extracted from: 02_Functions.sql
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
/*==============================================================================
  sp_UpsertAddress -- create or replace one typed address for a person.

  Keyed on (@PersonId, @AddressType) to match UQ_Addresses_Person_Type, so
  calling this twice with 'Permanent' updates rather than duplicates.

  @Address is the legacy single-string form. When the structured parameters are
  all NULL it is stored verbatim in AddressLine1, which is what makes
  vw_Users.Address read back exactly what the old API wrote.

  A blank address is a DELETE (deactivate), not an empty row: the old API cleared
  Users.Address by sending NULL, and that has to keep working.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpsertAddress
    @SchoolId       INT,
    @PersonId       INT,
    @AddressType    NVARCHAR(20)    = 'Permanent',
    @Address        NVARCHAR(255)   = NULL,   -- legacy single-line form
    @AddressLine1   NVARCHAR(255)   = NULL,
    @AddressLine2   NVARCHAR(255)   = NULL,
    @Landmark       NVARCHAR(100)   = NULL,
    @City           NVARCHAR(80)    = NULL,
    @State          NVARCHAR(80)    = NULL,
    @Country        NVARCHAR(80)    = NULL,
    @PostalCode     NVARCHAR(20)    = NULL,
    @IsPrimary      BIT             = 1,
    @ActorUserId    INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @AddressType = ISNULL(NULLIF(LTRIM(RTRIM(@AddressType)), N''), N'Permanent');
    SET @AddressLine1 = NULLIF(LTRIM(RTRIM(ISNULL(@AddressLine1, ISNULL(@Address, N'')))), N'');

    IF NOT EXISTS (SELECT 1 FROM dbo.Persons
                    WHERE Id = @PersonId
                      AND (SchoolId = @SchoolId
                           OR (SchoolId IS NULL AND @SchoolId IS NULL)))
    BEGIN
        THROW 51022, 'Person not found in this school.', 1;
    END

    /* Nothing to store: retire any existing address of this type. Deactivated
       rather than deleted so UQ_Addresses_Person_Type still guards the slot and
       the history survives; the filtered primary index only counts IsPrimary,
       so IsPrimary must be cleared too. */
    IF @AddressLine1 IS NULL
    BEGIN
        UPDATE dbo.Addresses
           SET IsActive   = 0,
               IsPrimary  = 0,
               ModifiedBy = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt  = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType = @AddressType;
        RETURN;
    END

    /* Only one row per person may be primary, so stand the others down first. */
    IF @IsPrimary = 1
        UPDATE dbo.Addresses
           SET IsPrimary = 0,
               UpdatedAt = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType <> @AddressType
           AND IsPrimary = 1;

    IF EXISTS (SELECT 1 FROM dbo.Addresses
                WHERE PersonId = @PersonId AND AddressType = @AddressType)
    BEGIN
        UPDATE dbo.Addresses
           SET AddressLine1 = @AddressLine1,
               AddressLine2 = @AddressLine2,
               Landmark     = @Landmark,
               City         = @City,
               State        = @State,
               Country      = @Country,
               PostalCode   = @PostalCode,
               IsPrimary    = @IsPrimary,
               IsActive     = 1,
               ModifiedBy   = ISNULL(@ActorUserId, ModifiedBy),
               UpdatedAt    = GETDATE()
         WHERE PersonId = @PersonId
           AND AddressType = @AddressType;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.Addresses (SchoolId, PersonId, AddressType, AddressLine1, AddressLine2,
                                   Landmark, City, State, Country, PostalCode, IsPrimary,
                                   CreatedBy, ModifiedBy)
        VALUES (@SchoolId, @PersonId, @AddressType, @AddressLine1, @AddressLine2,
                @Landmark, @City, @State, @Country, @PostalCode, @IsPrimary,
                @ActorUserId, @ActorUserId);
    END
END
GO

SET NOEXEC OFF;
GO
