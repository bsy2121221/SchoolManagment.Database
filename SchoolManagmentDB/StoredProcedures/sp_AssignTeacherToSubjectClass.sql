/*==============================================================================
  StoredProcedure : dbo.sp_AssignTeacherToSubjectClass
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
  sp_AssignTeacherToSubjectClass -- NEW.

  TeacherSubjectAssignments gates grade entry (sp_GetStudentsForGradeEntry
  refuses without a row here) but no procedure ever wrote to it, so grade entry
  could only be enabled by hand-inserting rows.

  Returns: Result, AssignmentId
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_AssignTeacherToSubjectClass
    @SchoolId   INT,
    @TeacherId  INT,
    @SubjectId  INT,
    @ClassId    INT,
    @IsActive   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Teachers WHERE SchoolId = @SchoolId AND Id = @TeacherId)
        BEGIN
            SELECT 'Error: Teacher not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Subjects WHERE SchoolId = @SchoolId AND Id = @SubjectId)
        BEGIN
            SELECT 'Error: Subject not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Classes WHERE SchoolId = @SchoolId AND Id = @ClassId)
        BEGIN
            SELECT 'Error: Class not found in this school' AS Result, CAST(NULL AS INT) AS AssignmentId;
            RETURN;
        END

        MERGE dbo.TeacherSubjectAssignments AS tgt
        USING (SELECT @SchoolId AS SchoolId, @TeacherId AS TeacherId,
                      @SubjectId AS SubjectId, @ClassId AS ClassId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.TeacherId = src.TeacherId
            AND tgt.SubjectId = src.SubjectId
            AND tgt.ClassId = src.ClassId
        WHEN MATCHED THEN
            UPDATE SET IsActive = @IsActive
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, TeacherId, SubjectId, ClassId, IsActive)
            VALUES (src.SchoolId, src.TeacherId, src.SubjectId, src.ClassId, @IsActive);

        SELECT 'Success' AS Result,
               (SELECT Id FROM dbo.TeacherSubjectAssignments
                 WHERE SchoolId = @SchoolId AND TeacherId = @TeacherId
                   AND SubjectId = @SubjectId AND ClassId = @ClassId) AS AssignmentId;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS AssignmentId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
