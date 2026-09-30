/*==============================================================================
  StoredProcedure : dbo.sp_UpdateParent
  Extracted from: 17_Procs_Parents.sql
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
  sp_UpdateParent -- admin edit of one parent.

  Returns: Result

  Every field named is written, so this is a replacement rather than a patch: a
  NULL phone number or address clears what is on file. That needs saying because
  sp_UpsertPerson treats a NULL @PhoneNumber as "leave it alone" (it is shared
  with the partial-update callers), which is why the phone is set explicitly
  below rather than left to the helper.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateParent
    @SchoolId       INT,
    @ParentId       INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Occupation     NVARCHAR(100) = NULL,
    @AnnualIncome   DECIMAL(12,2) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Parents
                                WHERE SchoolId = @SchoolId AND Id = @ParentId);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        IF NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Names, email and address, fanned out over Persons / Users / Addresses.
           Passing @Address through means a blank one deactivates the address row,
           which is sp_UpsertAddress's documented behaviour. */
        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @ModifiedBy;

        /* The one field the helper cannot clear. Without this an admin removing a
           parent's phone number would see it reappear on the next read. */
        UPDATE per
           SET per.PhoneNumber = @PhoneNumber,
               per.UpdatedAt   = GETDATE()
        FROM dbo.Persons AS per
        INNER JOIN dbo.Users AS usr ON usr.PersonId = per.Id
        WHERE usr.Id = @UserId
          AND usr.SchoolId = @SchoolId;

        UPDATE dbo.Parents
           SET Occupation   = @Occupation,
               AnnualIncome = @AnnualIncome,
               UpdatedAt    = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @ParentId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @ModifiedBy,
            @Action = 'Parent.Update', @EntityType = 'Parent', @EntityId = @ParentId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
