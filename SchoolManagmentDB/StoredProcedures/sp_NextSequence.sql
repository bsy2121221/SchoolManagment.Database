/*==============================================================================
  StoredProcedure : dbo.sp_NextSequence
  Extracted from: 02_Functions.sql
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
  sp_NextSequence -- atomically claim the next number in a per-school counter.

  @SequenceName: 'Student' | 'Employee' | 'Receipt' | 'Roll:<ClassId>'

  MERGE ... WITH (HOLDLOCK) is the standard safe upsert: HOLDLOCK takes a range
  lock on the key so two sessions cannot both take the NOT MATCHED branch and
  collide on the primary key. Enrolling the same class from two sessions at once
  therefore yields two distinct roll numbers.

  Call inside the caller's transaction so the number is rolled back with the
  rest of the work if registration fails.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_NextSequence
    @SchoolId       INT,
    @SequenceName   NVARCHAR(50),
    @NextValue      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Claimed TABLE (Val INT);

    MERGE dbo.SchoolSequences WITH (HOLDLOCK) AS tgt
    USING (SELECT @SchoolId AS SchoolId, @SequenceName AS SequenceName) AS src
        ON tgt.SchoolId = src.SchoolId
       AND tgt.SequenceName = src.SequenceName
    WHEN MATCHED THEN
        UPDATE SET LastValue = tgt.LastValue + 1,
                   UpdatedAt = GETDATE()
    WHEN NOT MATCHED THEN
        INSERT (SchoolId, SequenceName, LastValue)
        VALUES (src.SchoolId, src.SequenceName, 1)
    OUTPUT inserted.LastValue INTO @Claimed;

    SELECT @NextValue = Val FROM @Claimed;
END
GO

SET NOEXEC OFF;
GO
