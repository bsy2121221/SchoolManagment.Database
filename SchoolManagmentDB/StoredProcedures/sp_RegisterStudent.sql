/*==============================================================================
  StoredProcedure : dbo.sp_RegisterStudent
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
  sp_RegisterStudent

  Returns: Result, UserId, StudentRecordId, Username, StudentId, RollNumber,
           ClassName (the first six are the original column names; ClassName is
           new, because StudentRegistrationResponseDTO declares it)

  The default password is the shared Temp@123 hash with
  RequirePasswordChange = 1, exactly as before -- the account cannot be used
  until the student sets their own password.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RegisterStudent
    @SchoolId           INT,
    @FirstName          NVARCHAR(50),
    @LastName           NVARCHAR(50),
    @Email              NVARCHAR(100),
    @PhoneNumber        NVARCHAR(15) = NULL,
    @Address            NVARCHAR(255) = NULL,
    @ClassId            INT = NULL,
    @DateOfBirth        DATE = NULL,
    @Gender             NVARCHAR(10) = NULL,
    @FatherName         NVARCHAR(100) = NULL,
    @MotherName         NVARCHAR(100) = NULL,
    @BloodGroup         NVARCHAR(5) = NULL,
    @RegistrationYear   INT = NULL,
    @PasswordHash       NVARCHAR(255) = NULL,
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF NULLIF(LTRIM(RTRIM(ISNULL(@Email, N''))), N'') IS NULL
        BEGIN
            SELECT 'Error: Email is required' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* The class must belong to THIS school. Without this check a School A
           admin passing a School B class id would be stopped only by the
           composite FK, with an unhelpful error message. */
        DECLARE @ClassName NVARCHAR(50), @MaxStudents INT;

        IF @ClassId IS NOT NULL
        BEGIN
            SELECT @ClassName = ClassName, @MaxStudents = MaxStudents
            FROM dbo.Classes
            WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1;

            IF @ClassName IS NULL
            BEGIN
                SELECT 'Error: Class not found in this school' AS Result,
                       CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                       CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                       CAST(NULL AS NVARCHAR(10)) AS RollNumber;
                RETURN;
            END

            IF (SELECT COUNT(*) FROM dbo.Students
                 WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1) >= @MaxStudents
            BEGIN
                SELECT 'Error: Class ' + @ClassName + ' is full' AS Result,
                       CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                       CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                       CAST(NULL AS NVARCHAR(10)) AS RollNumber;
                RETURN;
            END
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: Email already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* Default to the school's own academic year, not the calendar year, so
           admission numbers do not roll over mid-session. */
        SET @RegistrationYear = ISNULL(@RegistrationYear,
                                       dbo.fn_AcademicYear(@SchoolId, CAST(GETDATE() AS DATE)));

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        BEGIN TRANSACTION;

        /* Roll numbers are per class; a student with no class yet falls back to
           the school-wide admission counter. Claimed inside the transaction so
           a failed registration does not burn a number. */
        DECLARE @Seq INT;
        DECLARE @SeqName NVARCHAR(50) =
            CASE WHEN @ClassId IS NULL THEN N'Student'
                 ELSE N'Roll:' + CAST(@ClassId AS NVARCHAR(10)) END;

        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = @SeqName, @NextValue = @Seq OUTPUT;

        DECLARE @LabelForId NVARCHAR(50) = ISNULL(@ClassName, N'GEN');
        DECLARE @Username  NVARCHAR(80) = dbo.fn_GenerateStudentUsername(@Code, @LabelForId, @RegistrationYear, @Seq);
        DECLARE @StudentId NVARCHAR(40) = dbo.fn_GenerateStudentId(@Code, @LabelForId, @RegistrationYear, @Seq);
        DECLARE @RollNumber NVARCHAR(10) =
            CASE WHEN @ClassId IS NULL THEN NULL
                 ELSE RIGHT(N'000' + CAST(@Seq AS NVARCHAR(10)), CASE WHEN @Seq > 999 THEN LEN(CAST(@Seq AS NVARCHAR(10))) ELSE 3 END)
            END;

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Generated username already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
                   CAST(NULL AS NVARCHAR(10)) AS RollNumber, CAST(NULL AS NVARCHAR(50)) AS ClassName;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        DECLARE @Hash NVARCHAR(255) = ISNULL(@PasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        /* Persons + Users + Addresses in one call; RoleId 4 is Student. Already
           inside this procedure's transaction, so a later failure unwinds all of
           it. */
        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @Hash,
            @RoleId                = 4,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = 1,
            @ActorUserId           = @PerformedByUserId,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        INSERT INTO dbo.Students (SchoolId, UserId, StudentId, ClassId, RollNumber, DateOfBirth,
                                  Gender, FatherName, MotherName, BloodGroup, AdmissionDate)
        VALUES (@SchoolId, @UserId, @StudentId, @ClassId, @RollNumber, @DateOfBirth,
                @Gender, @FatherName, @MotherName, @BloodGroup, CAST(GETDATE() AS DATE));

        DECLARE @StudentRecordId INT = CAST(SCOPE_IDENTITY() AS INT);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Student.Register', @EntityType = 'Student', @EntityId = @StudentRecordId,
            @Details = @StudentId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @UserId AS UserId,
               @StudentRecordId AS StudentRecordId,
               @Username AS Username,
               @StudentId AS StudentId,
               @RollNumber AS RollNumber,
               /* ClassName is on StudentRegistrationResponseDTO and the class was
                  already looked up above, so the caller does not need a second
                  round trip to tell the admin which class the student landed in. */
               @ClassName AS ClassName;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS StudentRecordId,
               CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(40)) AS StudentId,
               CAST(NULL AS NVARCHAR(10)) AS RollNumber;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
