/*==============================================================================
  StoredProcedure : dbo.sp_CreateSubject
  Extracted from: 10_Procs_Academics.sql
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
  sp_CreateSubject -- NEW. Returns: Result, SubjectId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateSubject
    @SchoolId       INT,
    @SubjectName    NVARCHAR(100),
    @SubjectCode    NVARCHAR(20),
    @Grade          NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        SET @SubjectCode = UPPER(LTRIM(RTRIM(ISNULL(@SubjectCode, N''))));

        IF @SubjectCode = N''
        BEGIN
            SELECT 'Error: Subject code is required' AS Result, CAST(NULL AS INT) AS SubjectId;
            RETURN;
        END

        /* Codes are unique per school, not globally -- two schools may both use
           'MATH10'. Soft-deleted rows still hold the code, so a re-created
           subject is reactivated rather than duplicated. */
        DECLARE @Existing INT = (SELECT Id FROM dbo.Subjects
                                  WHERE SchoolId = @SchoolId AND SubjectCode = @SubjectCode);

        IF @Existing IS NOT NULL
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.Subjects WHERE Id = @Existing AND IsActive = 1)
            BEGIN
                SELECT 'Error: A subject with this code already exists' AS Result,
                       CAST(NULL AS INT) AS SubjectId;
                RETURN;
            END

            UPDATE dbo.Subjects
               SET SubjectName = @SubjectName,
                   Grade       = @Grade,
                   IsActive    = 1,
                   UpdatedAt   = GETDATE()
             WHERE Id = @Existing;

            SELECT 'Success' AS Result, @Existing AS SubjectId;
            RETURN;
        END

        INSERT INTO dbo.Subjects (SchoolId, SubjectName, SubjectCode, Grade)
        VALUES (@SchoolId, @SubjectName, @SubjectCode, @Grade);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS SubjectId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS SubjectId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
