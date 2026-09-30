/*==============================================================================
  StoredProcedure : dbo.sp_LinkStudentParent
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
  sp_LinkStudentParent -- attach a parent to a student.

  Both ids are checked against @SchoolId first, so a mismatched pair produces a
  clear message rather than a composite-FK violation.

  ADDED IN THE PARENTS PASS: @Relationship is validated here rather than left to
  CK_StudentParents_Relationship. The constraint still backs it up, but its
  violation message ('The UPDATE statement conflicted with the CHECK constraint
  "CK_StudentParents_Relationship"...') reached the admin verbatim, and it does not
  say which three words are allowed. The unlink half of this pair lives in
  17_Procs_Parents.sql as sp_UnlinkStudentParent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_LinkStudentParent
    @SchoolId           INT,
    @StudentId          INT,
    @ParentId           INT,
    @Relationship       NVARCHAR(20),
    @PerformedByUserId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE SchoolId = @SchoolId AND Id = @StudentId)
        BEGIN
            SELECT 'Error: Student not found in this school' AS Result;
            RETURN;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.Parents WHERE SchoolId = @SchoolId AND Id = @ParentId)
        BEGIN
            SELECT 'Error: Parent not found in this school' AS Result;
            RETURN;
        END

        SET @Relationship = NULLIF(LTRIM(RTRIM(ISNULL(@Relationship, N''))), N'');

        IF @Relationship IS NULL OR @Relationship NOT IN (N'Father', N'Mother', N'Guardian')
        BEGIN
            SELECT 'Error: Relationship must be Father, Mother or Guardian' AS Result;
            RETURN;
        END

        MERGE dbo.StudentParents AS tgt
        USING (SELECT @SchoolId AS SchoolId, @StudentId AS StudentId, @ParentId AS ParentId) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ParentId = src.ParentId
        WHEN MATCHED THEN
            UPDATE SET Relationship = @Relationship, IsActive = 1
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ParentId, Relationship, IsActive)
            VALUES (src.SchoolId, src.StudentId, src.ParentId, @Relationship, 1);

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @PerformedByUserId,
            @Action = 'Parent.Link', @EntityType = 'StudentParent', @EntityId = @StudentId,
            @Details = @Relationship;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
