/*==============================================================================
  StoredProcedure : dbo.sp_UpdateSubject
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
  sp_UpdateSubject -- NEW. Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSubject
    @SchoolId       INT,
    @SubjectId      INT,
    @SubjectName    NVARCHAR(100),
    @SubjectCode    NVARCHAR(20),
    @Grade          NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects
                        WHERE SchoolId = @SchoolId AND Id = @SubjectId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result;
            RETURN;
        END

        SET @SubjectCode = UPPER(LTRIM(RTRIM(ISNULL(@SubjectCode, N''))));

        IF EXISTS (SELECT 1 FROM dbo.Subjects
                    WHERE SchoolId = @SchoolId AND SubjectCode = @SubjectCode AND Id <> @SubjectId)
        BEGIN
            SELECT 'Error: A subject with this code already exists' AS Result;
            RETURN;
        END

        UPDATE dbo.Subjects
           SET SubjectName = @SubjectName,
               SubjectCode = @SubjectCode,
               Grade       = @Grade,
               UpdatedAt   = GETDATE()
         WHERE SchoolId = @SchoolId AND Id = @SubjectId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
