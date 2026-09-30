/*==============================================================================
  StoredProcedure : dbo.sp_GetExaminationResults
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
  sp_GetExaminationResults -- NEW. The whole mark sheet for one examination,
  with class rank. Useful for the results screen and printing.

  Returns: StudentId, StudentNumber, RollNumber, FirstName, LastName,
           ObtainedMarks, MaxMarks, PassingMarks, Percentage, Grade, IsPass,
           Remarks, ClassRank
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetExaminationResults
    @SchoolId       INT,
    @ExaminationId  INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ClassId INT, @MaxMarks INT, @PassingMarks INT;

    SELECT @ClassId = ClassId, @MaxMarks = MaxMarks, @PassingMarks = PassingMarks
    FROM dbo.Examinations
    WHERE SchoolId = @SchoolId AND Id = @ExaminationId;

    SELECT s.Id AS StudentId,
           s.StudentId AS StudentNumber,
           s.RollNumber,
           u.FirstName,
           u.LastName,
           r.ObtainedMarks,
           @MaxMarks AS MaxMarks,
           @PassingMarks AS PassingMarks,
           CAST(ROUND(100.0 * r.ObtainedMarks / NULLIF(@MaxMarks, 0), 2) AS DECIMAL(5,2)) AS Percentage,
           r.Grade,
           CASE WHEN r.ObtainedMarks >= @PassingMarks THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPass,
           r.Remarks,
           /* Unmarked students rank last rather than first, which is what a plain
              ORDER BY on a NULL score would do. */
           RANK() OVER (ORDER BY CASE WHEN r.ObtainedMarks IS NULL THEN 1 ELSE 0 END,
                                 r.ObtainedMarks DESC) AS ClassRank
    FROM dbo.Students AS s
    INNER JOIN dbo.vw_Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
    LEFT JOIN dbo.Results AS r
           ON r.SchoolId = s.SchoolId
          AND r.StudentId = s.Id
          AND r.ExaminationId = @ExaminationId
          AND r.IsActive = 1
    WHERE s.SchoolId = @SchoolId
      AND s.ClassId = @ClassId
      AND s.IsActive = 1
      AND u.IsActive = 1
    ORDER BY ClassRank, TRY_CONVERT(INT, s.RollNumber), s.RollNumber;
END
GO

SET NOEXEC OFF;
GO
