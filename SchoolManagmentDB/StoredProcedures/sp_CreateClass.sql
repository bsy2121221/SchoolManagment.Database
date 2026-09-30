/*==============================================================================
  StoredProcedure : dbo.sp_CreateClass
  Extracted from: 08_Procs_Classes.sql
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
  sp_CreateClass -- Returns: Result, ClassId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateClass
    @SchoolId       INT,
    @ClassName      NVARCHAR(50),
    @Grade          NVARCHAR(10),
    @Section        NVARCHAR(5),
    @MaxStudents    INT,
    @ClassTeacherId INT = NULL      -- Teachers.Id
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        EXEC dbo.sp_AssertSchool @SchoolId;

        IF @ClassTeacherId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Teachers
                            WHERE SchoolId = @SchoolId AND Id = @ClassTeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Invalid class teacher' AS Result, CAST(NULL AS INT) AS ClassId;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND Grade = @Grade AND Section = @Section)
        BEGIN
            /* Not filtered on IsActive: UQ_Classes_School_GradeSection covers
               soft-deleted rows too, so the old "IsActive = 1" check let the
               insert through and then failed on the constraint. */
            SELECT 'Error: A class with this grade and section already exists' AS Result,
                   CAST(NULL AS INT) AS ClassId;
            RETURN;
        END

        INSERT INTO dbo.Classes (SchoolId, ClassName, Grade, Section, MaxStudents, ClassTeacherId)
        VALUES (@SchoolId, @ClassName, @Grade, @Section, @MaxStudents, @ClassTeacherId);

        SELECT 'Success' AS Result, CAST(SCOPE_IDENTITY() AS INT) AS ClassId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS ClassId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
