/*==============================================================================
  StoredProcedure : dbo.sp_UpdateStudentProfile
  Extracted from: 06_Procs_Students.sql
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
  sp_UpdateStudentProfile
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateStudentProfile
    @SchoolId       INT,
    @UserId         INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @DateOfBirth    DATE = NULL,
    @FatherName     NVARCHAR(100) = NULL,
    @MotherName     NVARCHAR(100) = NULL,
    @BloodGroup     NVARCHAR(5) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students
                        WHERE SchoolId = @SchoolId AND UserId = @UserId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        /* Name, phone and address are on Persons / Addresses now;
           sp_UpdateUserIdentity fans the edit out. @ModifiedBy defaults to the
           student themselves, since this is the self-service profile screen. */
        SET @ModifiedBy = ISNULL(@ModifiedBy, @UserId);

        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @ModifiedBy;

        UPDATE dbo.Students
           SET DateOfBirth = @DateOfBirth,
               FatherName  = @FatherName,
               MotherName  = @MotherName,
               BloodGroup  = @BloodGroup,
               UpdatedAt   = GETDATE()
         WHERE UserId = @UserId
           AND SchoolId = @SchoolId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UserId,
            @Action = 'Profile.Update', @EntityType = 'Student', @EntityId = @UserId;

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
