/*==============================================================================
  StoredProcedure : dbo.sp_UpdateTeacherDetails
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
  sp_UpdateTeacherDetails -- Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateTeacherDetails
    @SchoolId       INT,
    @TeacherId      INT,
    @FirstName      NVARCHAR(50),
    @LastName       NVARCHAR(50),
    @Email          NVARCHAR(100),
    @PhoneNumber    NVARCHAR(15) = NULL,
    @Address        NVARCHAR(255) = NULL,
    @Subject        NVARCHAR(100) = NULL,
    @Qualification  NVARCHAR(255) = NULL,
    @Experience     INT = NULL,
    @Salary         DECIMAL(10,2) = NULL,
    @SubjectIds     NVARCHAR(MAX) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @UserId INT = (SELECT UserId FROM dbo.Teachers
                                WHERE SchoolId = @SchoolId AND Id = @TeacherId);

        IF @UserId IS NULL
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Users
                    WHERE SchoolId = @SchoolId AND Email = @Email AND Id <> @UserId)
        BEGIN
            SELECT 'Error: Email already exists' AS Result;
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
            @ActorUserId = @ModifiedBy;

        UPDATE dbo.Teachers
           SET Subject       = @Subject,
               Qualification = @Qualification,
               Experience    = @Experience,
               Salary        = @Salary,
               UpdatedAt     = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @TeacherId;

        /* @Silent = 1: without it the inner result set arrives first and Dapper's
           FirstOrDefault() reads that instead of this procedure's Result. */
        IF @SubjectIds IS NOT NULL
            EXEC dbo.sp_AssignSubjectsToTeacher
                 @SchoolId = @SchoolId, @TeacherId = @TeacherId,
                 @SubjectIds = @SubjectIds, @Silent = 1;

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
