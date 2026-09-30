/*==============================================================================
  StoredProcedure : dbo.sp_CreateRefreshToken
  Extracted from: 04_Procs_Auth.sql
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
  sp_CreateRefreshToken -- issue a token, revoking the user's previous ones.

  @ExpiryDate is UTC (the API passes DateTime.UtcNow.AddDays(n)).

  Returns: Result, TokenId. TokenId is new -- AuthRepository already read the
  first column of this result set as an INT to populate RefreshToken.Id, which
  threw on the string 'Success' every time a token was issued.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CreateRefreshToken
    @UserId     INT,
    @Token      NVARCHAR(255),
    @ExpiryDate DATETIME,
    @IpAddress  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Id = @UserId AND IsActive = 1)
        BEGIN
            SELECT 'Error: User not found or inactive.' AS Result, CAST(NULL AS INT) AS TokenId;
            RETURN;
        END

        BEGIN TRANSACTION;

        UPDATE dbo.RefreshTokens
           SET IsActive = 0,
               RevokedAt = GETUTCDATE(),
               RevokedByIp = @IpAddress
         WHERE UserId = @UserId
           AND IsActive = 1;

        INSERT INTO dbo.RefreshTokens (UserId, Token, ExpiryDate, IsActive)
        VALUES (@UserId, @Token, @ExpiryDate, 1);

        DECLARE @TokenId INT = CAST(SCOPE_IDENTITY() AS INT);

        COMMIT TRANSACTION;

        SELECT 'Success' AS Result, @TokenId AS TokenId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result, CAST(NULL AS INT) AS TokenId;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
