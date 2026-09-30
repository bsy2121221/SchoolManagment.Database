/*==============================================================================
  StoredProcedure : dbo.sp_UpdateClass
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
  sp_UpdateClass -- Returns: Result
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateClass
    @SchoolId       INT,
    @ClassId        INT,
    @ClassName      NVARCHAR(50),
    @Grade          NVARCHAR(10),
    @Section        NVARCHAR(5),
    @MaxStudents    INT,
    @ClassTeacherId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Classes
                        WHERE SchoolId = @SchoolId AND Id = @ClassId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Class not found' AS Result;
            RETURN;
        END

        IF @ClassTeacherId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.Teachers
                            WHERE SchoolId = @SchoolId AND Id = @ClassTeacherId AND IsActive = 1)
        BEGIN
            SELECT 'Error: Invalid class teacher' AS Result;
            RETURN;
        END

        IF EXISTS (SELECT 1 FROM dbo.Classes
                    WHERE SchoolId = @SchoolId AND Grade = @Grade AND Section = @Section
                      AND Id <> @ClassId)
        BEGIN
            SELECT 'Error: A class with this grade and section already exists' AS Result;
            RETURN;
        END

        /* Shrinking MaxStudents below the current head-count would make
           sp_RegisterStudent reject every future admission with "class is full"
           and leave the class over capacity with no explanation. */
        DECLARE @Enrolled INT = (SELECT COUNT(*) FROM dbo.Students
                                  WHERE SchoolId = @SchoolId AND ClassId = @ClassId AND IsActive = 1);

        IF @MaxStudents < @Enrolled
        BEGIN
            SELECT 'Error: Capacity cannot be less than the ' + CAST(@Enrolled AS NVARCHAR(10))
                 + ' students already enrolled' AS Result;
            RETURN;
        END

        UPDATE dbo.Classes
           SET ClassName      = @ClassName,
               Grade          = @Grade,
               Section        = @Section,
               MaxStudents    = @MaxStudents,
               ClassTeacherId = @ClassTeacherId,
               UpdatedAt      = GETDATE()
         WHERE SchoolId = @SchoolId
           AND Id = @ClassId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
