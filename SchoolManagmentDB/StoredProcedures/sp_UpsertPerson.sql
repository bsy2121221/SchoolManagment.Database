/*==============================================================================
  StoredProcedure : dbo.sp_UpsertPerson
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
  sp_UpsertPerson -- create or update the Persons row behind a user.

  @PersonId NULL  -> insert, and return the new id in @PersonId.
  @PersonId given -> update, but only if that person belongs to @SchoolId.

  NULL means "leave alone" on update, so a caller that only knows the phone
  number does not blank out the name. On insert, @FirstName / @LastName are
  required.

  @SchoolId is NULL for the platform SuperAdmin only; sp_AssertSchool is
  therefore skipped in that one case rather than failing the whole call.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpsertPerson
    @SchoolId               INT,
    @FirstName              NVARCHAR(50)    = NULL,
    @LastName               NVARCHAR(50)    = NULL,
    @PhoneNumber            NVARCHAR(15)    = NULL,
    @AlternatePhoneNumber   NVARCHAR(15)    = NULL,
    @ActorUserId            INT             = NULL,
    @PersonId               INT             OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @SchoolId IS NOT NULL EXEC dbo.sp_AssertSchool @SchoolId;

    IF @PersonId IS NULL
    BEGIN
        IF NULLIF(LTRIM(RTRIM(ISNULL(@FirstName, N''))), N'') IS NULL
         OR NULLIF(LTRIM(RTRIM(ISNULL(@LastName,  N''))), N'') IS NULL
        BEGIN
            THROW 51020, 'First name and last name are required to create a person.', 1;
        END

        INSERT INTO dbo.Persons (SchoolId, FirstName, LastName, PhoneNumber,
                                 AlternatePhoneNumber, CreatedBy, ModifiedBy)
        VALUES (@SchoolId, LTRIM(RTRIM(@FirstName)), LTRIM(RTRIM(@LastName)), @PhoneNumber,
                @AlternatePhoneNumber, @ActorUserId, @ActorUserId);

        SET @PersonId = CAST(SCOPE_IDENTITY() AS INT);
        RETURN;
    END

    /* The SchoolId comparison has to tolerate NULL = NULL for the SuperAdmin. */
    IF NOT EXISTS (SELECT 1 FROM dbo.Persons
                    WHERE Id = @PersonId
                      AND (SchoolId = @SchoolId
                           OR (SchoolId IS NULL AND @SchoolId IS NULL)))
    BEGIN
        THROW 51021, 'Person not found in this school.', 1;
    END

    UPDATE dbo.Persons
       SET FirstName            = ISNULL(NULLIF(LTRIM(RTRIM(@FirstName)), N''), FirstName),
           LastName             = ISNULL(NULLIF(LTRIM(RTRIM(@LastName)),  N''), LastName),
           PhoneNumber          = ISNULL(@PhoneNumber,          PhoneNumber),
           AlternatePhoneNumber = ISNULL(@AlternatePhoneNumber, AlternatePhoneNumber),
           ModifiedBy           = ISNULL(@ActorUserId, ModifiedBy),
           UpdatedAt            = GETDATE()
     WHERE Id = @PersonId;
END
GO

SET NOEXEC OFF;
GO
