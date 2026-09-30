/*==============================================================================
  StoredProcedure : dbo.sp_RegisterTeacher
  Extracted from: 07_Procs_Teachers.sql
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
  sp_RegisterTeacher

  Returns: Result, UserId, TeacherRecordId, Username, EmployeeId
           (unchanged column names)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_RegisterTeacher
    @SchoolId           INT,
    @FirstName          NVARCHAR(50),
    @LastName           NVARCHAR(50),
    @Email              NVARCHAR(100),
    @PhoneNumber        NVARCHAR(15) = NULL,
    @Address            NVARCHAR(255) = NULL,
    @Subject            NVARCHAR(100) = NULL,
    @Qualification      NVARCHAR(255) = NULL,
    @Experience         INT = NULL,
    @Salary             DECIMAL(10,2) = NULL,
    @SubjectIds         NVARCHAR(MAX) = NULL,   -- comma-separated
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
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users WHERE SchoolId = @SchoolId AND Email = @Email)
        BEGIN
            SELECT 'Error: Email already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        DECLARE @Code NVARCHAR(12) = dbo.fn_SchoolCode(@SchoolId);

        BEGIN TRANSACTION;

        DECLARE @Seq INT;
        EXEC dbo.sp_NextSequence @SchoolId = @SchoolId, @SequenceName = N'Employee', @NextValue = @Seq OUTPUT;

        DECLARE @Username   NVARCHAR(80) = dbo.fn_GenerateTeacherUsername(@Code, @FirstName, @LastName, @Seq);
        DECLARE @EmployeeId NVARCHAR(30) = dbo.fn_GenerateTeacherEmployeeId(@Code, @Seq);

        /* Two teachers with the same initial + surname collide on the name part
           but not on the sequence suffix, so this only trips on a genuine
           duplicate. */
        IF EXISTS (SELECT 1 FROM dbo.Users WHERE Username = @Username)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 'Error: Generated username already exists' AS Result,
                   CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
                   CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
            RETURN;
        END

        /* BCrypt hash of Temp@123 (verified). */
        DECLARE @Hash NVARCHAR(255) = ISNULL(@PasswordHash,
            N'$2a$11$sOBr7CVGS.i2NiqK1seOgOCCdOfDXRNUkO6ZoqwF7m86fYAj4xJNO');

        /* Persons + Users + Addresses in one call; RoleId 3 is Teacher. */
        DECLARE @UserId INT, @PersonId INT;

        EXEC dbo.sp_CreateUserAccount
            @SchoolId              = @SchoolId,
            @Username              = @Username,
            @Email                 = @Email,
            @PasswordHash          = @Hash,
            @RoleId                = 3,
            @FirstName             = @FirstName,
            @LastName              = @LastName,
            @PhoneNumber           = @PhoneNumber,
            @Address               = @Address,
            @RequirePasswordChange = 1,
            @ActorUserId           = @PerformedByUserId,
            @UserId                = @UserId OUTPUT,
            @PersonId              = @PersonId OUTPUT;

        INSERT INTO dbo.Teachers (SchoolId, UserId, EmployeeId, Subject, Qualification,
                                  Experience, Salary, JoinDate)
        VALUES (@SchoolId, @UserId, @EmployeeId, @Subject, @Qualification,
                @Experience, @Salary, CAST(GETDATE() AS DATE));

        DECLARE @TeacherRecordId INT = CAST(SCOPE_IDENTITY() AS INT);

        IF NULLIF(LTRIM(RTRIM(ISNULL(@SubjectIds, N''))), N'') IS NOT NULL
            EXEC dbo.sp_AssignSubjectsToTeacher
                 @SchoolId = @SchoolId, @TeacherId = @TeacherRecordId,
                 @SubjectIds = @SubjectIds, @Silent = 1;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Teacher.Register', @EntityType = 'Teacher', @EntityId = @TeacherRecordId,
            @Details = @EmployeeId;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @UserId AS UserId,
               @TeacherRecordId AS TeacherRecordId,
               @Username AS Username,
               @EmployeeId AS EmployeeId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SELECT 'Error: ' + ERROR_MESSAGE() AS Result,
               CAST(NULL AS INT) AS UserId, CAST(NULL AS INT) AS TeacherRecordId,
               CAST(NULL AS NVARCHAR(80)) AS Username, CAST(NULL AS NVARCHAR(30)) AS EmployeeId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
