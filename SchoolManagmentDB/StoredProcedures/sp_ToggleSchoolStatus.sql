/*==============================================================================
  StoredProcedure : dbo.sp_ToggleSchoolStatus
  Extracted from: 03_Procs_Platform.sql
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
  sp_ToggleSchoolStatus -- suspend or restore a tenant.

  Deactivating a school also revokes its users' refresh tokens; otherwise a
  suspended school's staff would stay signed in until their tokens expired.
  sp_Login already refuses users whose school is inactive.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_ToggleSchoolStatus
    @SchoolId           INT,
    @IsActive           BIT,
    @UpdatedByUserId    INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
        BEGIN
            SELECT 'Error: School not found.' AS Result, CAST(NULL AS BIT) AS IsActive;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.Schools
           SET IsActive = @IsActive,
               UpdatedAt = GETDATE()
         WHERE Id = @SchoolId;

        IF @IsActive = 0
        BEGIN
            UPDATE rt
               SET rt.IsActive = 0,
                   rt.RevokedAt = GETUTCDATE()
            FROM dbo.RefreshTokens AS rt
            INNER JOIN dbo.Users AS u ON u.Id = rt.UserId
            WHERE u.SchoolId = @SchoolId
              AND rt.IsActive = 1;
        END

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedByUserId,
            @Action = 'School.ToggleStatus', @EntityType = 'School', @EntityId = @SchoolId,
            @Details = NULL;

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @IsActive AS IsActive;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS BIT) AS IsActive;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
