/*==============================================================================
  StoredProcedure : dbo.sp_BulkGradeEntry
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
  sp_BulkGradeEntry

  @GradeEntries: [{"StudentId":12,"ObtainedMarks":78,"Grade":"B","Remarks":""}, ...]
  Grade may be omitted or empty; it is then derived from the school's scale.

  Entries whose student is not in the examination's class, or whose marks fall
  outside 0..MaxMarks, are skipped and counted rather than aborting the batch --
  one bad row should not lose a teacher's whole entry screen.

  Two counting defects fixed. @Requested used to be taken *after* the
  StudentId/ObtainedMarks NULL filter, so an entry with a missing mark was
  neither saved nor reported as skipped -- it disappeared, and the caller was
  told Success. It is now taken from the raw OPENJSON row count, so
  EntriesSaved + EntriesSkipped always equals what was sent.

  And @In was declared with StudentId as a PRIMARY KEY, so a payload naming the
  same student twice raised a duplicate-key error that the CATCH turned into
  'Error: Violation of PRIMARY KEY ...' and lost the entire batch over one
  repeated row. Duplicates are now collapsed to their last occurrence, which is
  what a MERGE on the same key would have done anyway.

  Returns: Result, EntriesSaved, EntriesSkipped
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_BulkGradeEntry
    @SchoolId       INT,
    @ExaminationId  INT,
    @GradeEntries   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF ISJSON(ISNULL(@GradeEntries, N'')) <> 1
        BEGIN
            SELECT 'Error: GradeEntries is not valid JSON' AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
            RETURN;
        END

        DECLARE @ExamClassId INT, @MaxMarks INT;

        SELECT @ExamClassId = ClassId, @MaxMarks = MaxMarks
        FROM dbo.Examinations
        WHERE SchoolId = @SchoolId AND Id = @ExaminationId AND IsActive = 1;

        IF @ExamClassId IS NULL
        BEGIN
            SELECT 'Error: Examination not found in this school' AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
            RETURN;
        END

        /* Raw first, so nothing can be dropped without being counted. */
        DECLARE @Raw TABLE (Ordinal INT, StudentId INT, ObtainedMarks INT,
                            Grade NVARCHAR(5), Remarks NVARCHAR(255));

        INSERT INTO @Raw (Ordinal, StudentId, ObtainedMarks, Grade, Remarks)
        SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
               j.StudentId, j.ObtainedMarks, j.Grade, j.Remarks
        FROM OPENJSON(@GradeEntries)
             WITH (StudentId     INT           '$.StudentId',
                   ObtainedMarks INT           '$.ObtainedMarks',
                   Grade         NVARCHAR(5)   '$.Grade',
                   Remarks       NVARCHAR(255) '$.Remarks') AS j;

        DECLARE @Requested INT = (SELECT COUNT(*) FROM @Raw);

        DECLARE @In TABLE (StudentId INT PRIMARY KEY, ObtainedMarks INT,
                           Grade NVARCHAR(5), Remarks NVARCHAR(255));

        /* Last occurrence wins for a repeated StudentId, matching what a MERGE on
           the same key would settle on, instead of erroring on the PK. */
        INSERT INTO @In (StudentId, ObtainedMarks, Grade, Remarks)
        SELECT d.StudentId, d.ObtainedMarks, d.Grade, d.Remarks
        FROM (SELECT r.*,
                     ROW_NUMBER() OVER (PARTITION BY r.StudentId
                                            ORDER BY r.Ordinal DESC) AS Recency
                FROM @Raw AS r
               WHERE r.StudentId IS NOT NULL
                 AND r.ObtainedMarks IS NOT NULL) AS d
        WHERE d.Recency = 1;

        DECLARE @Valid TABLE (StudentId INT PRIMARY KEY, ObtainedMarks INT,
                              Grade NVARCHAR(5), Remarks NVARCHAR(255));

        INSERT INTO @Valid (StudentId, ObtainedMarks, Grade, Remarks)
        SELECT i.StudentId,
               i.ObtainedMarks,
               COALESCE(NULLIF(i.Grade, N''), dbo.fn_CalculateGrade(@SchoolId, i.ObtainedMarks, @MaxMarks)),
               i.Remarks
        FROM @In AS i
        INNER JOIN dbo.Students AS s
                ON s.SchoolId = @SchoolId AND s.Id = i.StudentId
               AND s.ClassId = @ExamClassId AND s.IsActive = 1
        WHERE i.ObtainedMarks BETWEEN 0 AND @MaxMarks;

        BEGIN TRANSACTION;

        MERGE dbo.Results WITH (HOLDLOCK) AS tgt
        USING (SELECT @SchoolId AS SchoolId, StudentId, @ExaminationId AS ExaminationId,
                      ObtainedMarks, Grade, Remarks
                 FROM @Valid) AS src
            ON  tgt.SchoolId = src.SchoolId
            AND tgt.StudentId = src.StudentId
            AND tgt.ExaminationId = src.ExaminationId
        WHEN MATCHED THEN
            UPDATE SET ObtainedMarks = src.ObtainedMarks,
                       Grade         = src.Grade,
                       Remarks       = src.Remarks,
                       IsActive      = 1,
                       UpdatedAt     = GETDATE()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (SchoolId, StudentId, ExaminationId, ObtainedMarks, Grade, Remarks)
            VALUES (src.SchoolId, src.StudentId, src.ExaminationId,
                    src.ObtainedMarks, src.Grade, src.Remarks);

        DECLARE @Saved INT = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result,
               @Saved AS EntriesSaved,
               @Requested - @Saved AS EntriesSkipped;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, 0 AS EntriesSaved, 0 AS EntriesSkipped;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
