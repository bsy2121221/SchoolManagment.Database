/*==============================================================================
  StoredProcedure : dbo.sp_UpdateStudent
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
  sp_UpdateStudent -- NEW. The administrator's edit, keyed on Students.Id.

  sp_UpdateStudentProfile above is the student's own edit and stays as it is: it
  is keyed on @UserId, defaults @ModifiedBy to the student, and cannot set
  Gender. An admin screen has the student record's id in hand, not the account's,
  and StudentUpdateDTO does carry Gender -- so this is a second procedure rather
  than four more optional parameters on that one.

  ClassId is deliberately absent, as it is from StudentUpdateDTO: moving a
  student between classes has to renumber the roll and check capacity, which is
  what sp_PromoteStudent does.

  Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateStudent
    @SchoolId          INT,
    @StudentId         INT,              -- Students.Id, not the admission number
    @FirstName         NVARCHAR(50),
    @LastName          NVARCHAR(50),
    @Email             NVARCHAR(100),
    @PhoneNumber       NVARCHAR(15) = NULL,
    @DateOfBirth       DATE = NULL,
    @Gender            NVARCHAR(10) = NULL,
    @FatherName        NVARCHAR(100) = NULL,
    @MotherName        NVARCHAR(100) = NULL,
    @BloodGroup        NVARCHAR(5) = NULL,
    @Address           NVARCHAR(255) = NULL,
    @PerformedByUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Students
                                WHERE SchoolId = @SchoolId AND Id = @StudentId AND IsActive = 1);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        SET @Email = NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'');

        IF @Email IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result;
            RETURN;
        END

        /* Checked here as well as inside sp_UpdateUserIdentity, which THROWs:
           the sentence a person reads should not depend on an error number. */
        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
            RETURN;
        END

        SET @Gender = NULLIF(LTRIM(RTRIM(ISNULL(@Gender, N''))), N'');

        /* CK_Students_Gender would otherwise raise a constraint name at the
           user. The list is the constraint's, so the two cannot drift apart
           without this check failing loudly in 16_Verify.sql. */
        IF @Gender IS NOT NULL AND @Gender NOT IN (N'Male', N'Female', N'Other')
        BEGIN
            SELECT 'Error: Gender must be Male, Female or Other' AS Result;
            RETURN;
        END

        BEGIN TRANSACTION;

        EXEC dbo.sp_UpdateUserIdentity
            @SchoolId    = @SchoolId,
            @UserId      = @UserId,
            @FirstName   = @FirstName,
            @LastName    = @LastName,
            @Email       = @Email,
            @PhoneNumber = @PhoneNumber,
            @Address     = @Address,
            @ActorUserId = @PerformedByUserId;

        UPDATE dbo.Students
           SET DateOfBirth = @DateOfBirth,
               Gender      = @Gender,
               FatherName  = @FatherName,
               MotherName  = @MotherName,
               BloodGroup  = @BloodGroup,
               UpdatedAt   = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @StudentId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Update', @EntityType = 'Student', @EntityId = @StudentId;

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
