/*==============================================================================
  StoredProcedure : dbo.sp_UpdateSchool
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
  sp_UpdateSchool
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateSchool
    @SchoolId                   INT,
    @SchoolName                 NVARCHAR(150)   = NULL,
    @Subdomain                  NVARCHAR(63)    = NULL,
    @Address                    NVARCHAR(255)   = NULL,
    @City                       NVARCHAR(80)    = NULL,
    @State                      NVARCHAR(80)    = NULL,
    @Country                    NVARCHAR(80)    = NULL,
    @PostalCode                 NVARCHAR(20)    = NULL,
    @ContactEmail               NVARCHAR(100)   = NULL,
    @ContactPhone               NVARCHAR(20)    = NULL,
    @PrincipalName              NVARCHAR(100)   = NULL,
    @LogoUrl                    NVARCHAR(500)   = NULL,
    @ThemeColor                 NVARCHAR(20)    = NULL,
    @AcademicYearStartMonth     TINYINT         = NULL,
    @ClearSubdomain             BIT             = 0,
    @UpdatedByUserId            INT             = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Schools WHERE Id = @SchoolId)
        BEGIN
            SELECT 'Error: School not found.' AS Result;
            RETURN;
        END

        SET @Subdomain = NULLIF(LOWER(LTRIM(RTRIM(ISNULL(@Subdomain, N'')))), N'');

        IF @Subdomain IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.Schools WHERE Subdomain = @Subdomain AND Id <> @SchoolId)
        BEGIN
            SELECT 'Error: Subdomain ''' + @Subdomain + ''' is already in use.' AS Result;
            RETURN;
        END

        /* SchoolCode is intentionally not updatable: it is embedded in every
           username and admission number already issued. */
        UPDATE dbo.Schools
           SET SchoolName             = ISNULL(@SchoolName, SchoolName),
               Subdomain              = CASE WHEN @ClearSubdomain = 1 THEN NULL
                                             ELSE ISNULL(@Subdomain, Subdomain) END,
               Address                = ISNULL(@Address, Address),
               City                   = ISNULL(@City, City),
               State                  = ISNULL(@State, State),
               Country                = ISNULL(@Country, Country),
               PostalCode             = ISNULL(@PostalCode, PostalCode),
               ContactEmail           = ISNULL(@ContactEmail, ContactEmail),
               ContactPhone           = ISNULL(@ContactPhone, ContactPhone),
               PrincipalName          = ISNULL(@PrincipalName, PrincipalName),
               LogoUrl                = ISNULL(@LogoUrl, LogoUrl),
               ThemeColor             = ISNULL(@ThemeColor, ThemeColor),
               AcademicYearStartMonth = ISNULL(@AcademicYearStartMonth, AcademicYearStartMonth),
               UpdatedAt              = GETDATE()
         WHERE Id = @SchoolId;

        EXEC dbo.sp_LogAudit
            @SchoolId = @SchoolId, @UserId = @UpdatedByUserId,
            @Action = 'School.Update', @EntityType = 'School', @EntityId = @SchoolId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

SET NOEXEC OFF;
GO
