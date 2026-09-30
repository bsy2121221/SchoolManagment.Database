/*==============================================================================
  StoredProcedure : dbo.sp_GetSettingByKey
  Extracted from: 13_Procs_Settings.sql
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
  sp_GetSettingByKey -- returns no row when the key does not exist.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetSettingByKey
    @SchoolId   INT,
    @Category   NVARCHAR(50),
    @SettingKey NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT Id,
           Category,
           SettingKey,
           SettingValue,
           DataType,
           Description,
           IsActive,
           CreatedAt,
           UpdatedAt,
           CreatedBy,
           UpdatedBy,
           SchoolId
    FROM dbo.Settings
    WHERE SchoolId = @SchoolId
      AND Category = @Category
      AND SettingKey = @SettingKey
      AND IsActive = 1;
END
GO

/*==============================================================================
  fn_IsValidSettingValue -- does @Value make sense for @DataType?

  Used by both save procs so a 'number' setting cannot end up holding text.
  Returns 1 for valid, 0 for invalid. An unknown @DataType returns 0.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_IsValidSettingValue
(
    @DataType NVARCHAR(20),
    @Value    NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    IF @Value IS NULL RETURN 0;

    RETURN CASE
             WHEN @DataType = 'string'  THEN 1
             WHEN @DataType = 'number'  THEN CASE WHEN TRY_CONVERT(DECIMAL(38, 10), @Value) IS NULL
                                                  THEN 0 ELSE 1 END
             /* The React settings page posts JS booleans, the seed data uses
                'true'/'false', and some older rows hold '1'/'0'. All accepted. */
             WHEN @DataType = 'boolean' THEN CASE WHEN LOWER(@Value) IN ('true', 'false', '1', '0')
                                                  THEN 1 ELSE 0 END
             WHEN @DataType = 'json'    THEN CASE WHEN ISJSON(@Value) = 1 THEN 1 ELSE 0 END
             ELSE 0
           END;
END
GO

SET NOEXEC OFF;
GO
