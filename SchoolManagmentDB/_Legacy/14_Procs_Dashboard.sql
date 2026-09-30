/*==============================================================================
  14_Procs_Dashboard.sql  --  Dashboard, profile activity, profile pictures.

  FIXES
    * sp_GetDashboardStats took no @SchoolId. Every count was installation-wide,
      so as soon as a second school existed each admin saw the sum of all
      schools. This is the single most visible symptom of the old single-tenant
      design.
    * Its counts came from Users.Role, not from the Students/Teachers/Parents
      tables. A student whose Students row had been soft-deleted still counted as
      a student for as long as the login stayed enabled. Counts now come from the
      role tables joined to an active user.
    * OverdueFees was:
          Id NOT IN (SELECT FeeId FROM FeePayments GROUP BY FeeId
                     HAVING SUM(AmountPaid) >= (SELECT Amount FROM Fees WHERE Id = FeeId))
      Three problems. The correlated scalar subquery re-reads Fees per group and
      cannot use an index. NOT IN over a subquery that can yield NULL FeeId
      silently returns nothing at all. And SUM(AmountPaid) counted Failed and
      Refunded payments as money received, so an overdue fee looked settled.
      Rewritten as a LEFT JOIN onto payments pre-aggregated over completed
      payments only -- same shape used in 08 and 11.
    * sp_GetProfileActivities invented its rows from Users.UpdatedAt: both the
      "Profile Update" and "Password Change" entries carried the same timestamp,
      and the password row appeared for every user with
      RequirePasswordChange = 0 whether or not a password had ever been changed.
      It now reads the real AuditLog.
    * sp_CheckEmailAvailability compared emails across the whole installation.
      With UQ_Users_School_Email the same parent address may legitimately exist
      in two schools, so the check is per school.
    * sp_GetProfilePicture / sp_UpdateProfilePicture read and wrote four columns
      that no script ever created -- both failed with "Invalid column name" every
      time they were called. The columns exist in 01_Schema.sql now, on
      dbo.Persons, and both procedures reach them through Users.PersonId.
    * sp_DeleteProfilePicture was called by UserRepository but never existed.
      Added.
==============================================================================*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    PRINT '*** ABORTED: current database is [' + DB_NAME() + ']. ***';
    SET NOEXEC ON;
END
GO

/*==============================================================================
  sp_GetDashboardStats

  Column names kept: TotalStudents, TotalTeachers, TotalParents, TotalClasses,
  TodayPresent, TodayAbsent, OverdueFees.
  Added at the end (extra columns are ignored by existing Dapper mappings):
  TotalSubjects, FeesOutstandingAmount, FeesCollectedThisMonth.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetDashboardStats
    @SchoolId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MonthStart DATE = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);

    SELECT (SELECT COUNT(*)
              FROM dbo.Students AS s
              INNER JOIN dbo.Users AS u ON u.SchoolId = s.SchoolId AND u.Id = s.UserId
             WHERE s.SchoolId = @SchoolId AND s.IsActive = 1 AND u.IsActive = 1) AS TotalStudents,

           (SELECT COUNT(*)
              FROM dbo.Teachers AS t
              INNER JOIN dbo.Users AS u ON u.SchoolId = t.SchoolId AND u.Id = t.UserId
             WHERE t.SchoolId = @SchoolId AND t.IsActive = 1 AND u.IsActive = 1) AS TotalTeachers,

           (SELECT COUNT(*)
              FROM dbo.Parents AS p
              INNER JOIN dbo.Users AS u ON u.SchoolId = p.SchoolId AND u.Id = p.UserId
             WHERE p.SchoolId = @SchoolId AND p.IsActive = 1 AND u.IsActive = 1) AS TotalParents,

           (SELECT COUNT(*) FROM dbo.Classes
             WHERE SchoolId = @SchoolId AND IsActive = 1) AS TotalClasses,

           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND AttendanceDate = @Today AND IsPresent = 1) AS TodayPresent,

           (SELECT COUNT(*) FROM dbo.Attendance
             WHERE SchoolId = @SchoolId AND AttendanceDate = @Today AND IsPresent = 0) AS TodayAbsent,

           (SELECT COUNT(*)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId
               AND f.IsActive = 1
               AND f.DueDate < @Today
               AND ISNULL(p.Paid, 0) < f.Amount) AS OverdueFees,

           (SELECT COUNT(*) FROM dbo.Subjects
             WHERE SchoolId = @SchoolId AND IsActive = 1) AS TotalSubjects,

           (SELECT ISNULL(SUM(f.Amount - ISNULL(p.Paid, 0)), 0)
              FROM dbo.Fees AS f
              LEFT JOIN (SELECT SchoolId, FeeId, SUM(AmountPaid) AS Paid
                           FROM dbo.FeePayments
                          WHERE PaymentStatus = 'Completed'
                          GROUP BY SchoolId, FeeId) AS p
                     ON p.SchoolId = f.SchoolId AND p.FeeId = f.Id
             WHERE f.SchoolId = @SchoolId
               AND f.IsActive = 1
               AND ISNULL(p.Paid, 0) < f.Amount) AS FeesOutstandingAmount,

           (SELECT ISNULL(SUM(AmountPaid), 0)
              FROM dbo.FeePayments
             WHERE SchoolId = @SchoolId
               AND PaymentStatus = 'Completed'
               AND PaymentDate >= @MonthStart) AS FeesCollectedThisMonth;
END
GO

/*==============================================================================
  sp_GetProfileActivities -- the signed-in user's own recent activity.

  Column names kept: ActivityType, ActivityDate, ActivityDescription.
  EntityType / EntityId / IpAddress follow, matching sp_GetUserActivityLog.

  @SchoolId is optional so a SuperAdmin (SchoolId NULL, and therefore
  AuditLog.SchoolId NULL on their platform actions) can read their own history.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetProfileActivities
    @SchoolId   INT = NULL,
    @UserId     INT,
    @TopCount   INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    /* A caller passing @TopCount = 0 or a negative number used to get an
       immediate error out of TOP; clamp instead. */
    SET @TopCount = CASE WHEN ISNULL(@TopCount, 10) BETWEEN 1 AND 500 THEN @TopCount ELSE 10 END;

    SELECT TOP (@TopCount)
           al.Action AS ActivityType,
           al.CreatedAt AS ActivityDate,
           CASE
               WHEN al.Details IS NOT NULL THEN al.Action + ': ' + al.Details
               WHEN al.EntityType IS NOT NULL THEN al.Action + ' on ' + al.EntityType
               ELSE al.Action
           END AS ActivityDescription,
           al.EntityType,
           al.EntityId,
           al.IpAddress
    FROM dbo.AuditLog AS al
    WHERE al.UserId = @UserId
      AND (@SchoolId IS NULL OR al.SchoolId = @SchoolId)
    ORDER BY al.CreatedAt DESC;
END
GO

/*==============================================================================
  sp_CheckEmailAvailability -- Returns: IsAvailable, Message

  Scoped to the school: UQ_Users_School_Email means the same address may exist
  once per school. @SchoolId NULL is the platform scope (SuperAdmin), which is
  compared against the other SchoolId NULL users rather than against everybody.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_CheckEmailAvailability
    @SchoolId   INT = NULL,
    @UserId     INT,
    @Email      NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1
                 FROM dbo.Users
                WHERE Email = @Email
                  AND Id <> @UserId
                  AND ((SchoolId = @SchoolId) OR (@SchoolId IS NULL AND SchoolId IS NULL)))
        SELECT CAST(0 AS BIT) AS IsAvailable,
               'Email already in use by another user' AS Message;
    ELSE
        SELECT CAST(1 AS BIT) AS IsAvailable,
               'Email is available' AS Message;
END
GO

/*==============================================================================
  sp_GetProfilePicture

  Returns: ProfilePicture, ProfilePictureFileName, ProfilePictureContentType,
           ProfilePictureUploadDate

  Keyed on Users.Id, which the API takes from the token rather than from the
  request body. @SchoolId is an optional extra guard, and must stay optional so
  a SuperAdmin can fetch their own.

  The bytes live on dbo.Persons now -- a photograph is a property of the human,
  not of their login. Still addressed by user id, so the API did not change.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_GetProfilePicture
    @SchoolId   INT = NULL,
    @UserId     INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT p.ProfilePicture,
           p.ProfilePictureFileName,
           p.ProfilePictureContentType,
           p.ProfilePictureUploadDate
    FROM dbo.Users AS u
    INNER JOIN dbo.Persons AS p ON p.Id = u.PersonId
    WHERE u.Id = @UserId
      AND (@SchoolId IS NULL OR u.SchoolId = @SchoolId);
END
GO

/*==============================================================================
  sp_UpdateProfilePicture -- Returns: Result

  @ProfilePicture NULL clears the picture, which is how the UI's "remove photo"
  action is expressed; the filename, content type and upload date are cleared
  with it instead of being left pointing at bytes that are gone.

  Writes dbo.Persons, resolved through Users.PersonId. @ModifiedBy defaults to
  @UserId because uploading your own photo is the normal case.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_UpdateProfilePicture
    @SchoolId       INT = NULL,
    @UserId         INT,
    @ProfilePicture VARBINARY(MAX),
    @FileName       NVARCHAR(255) = NULL,
    @ContentType    NVARCHAR(100) = NULL,
    @ModifiedBy     INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @PersonId INT =
            (SELECT PersonId FROM dbo.Users
              WHERE Id = @UserId
                AND (@SchoolId IS NULL OR SchoolId = @SchoolId));

        IF @PersonId IS NULL
        BEGIN
            SELECT 'Error: User not found' AS Result;
            RETURN;
        END

        SET @ModifiedBy = ISNULL(@ModifiedBy, @UserId);

        UPDATE dbo.Persons
           SET ProfilePicture            = @ProfilePicture,
               ProfilePictureFileName    = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE @FileName END,
               ProfilePictureContentType = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE @ContentType END,
               ProfilePictureUploadDate  = CASE WHEN @ProfilePicture IS NULL THEN NULL ELSE GETDATE() END,
               ModifiedBy                = @ModifiedBy,
               UpdatedAt                 = GETDATE()
         WHERE Id = @PersonId;

        SELECT 'Success' AS Result;
    END TRY
    BEGIN CATCH
        SELECT 'Error: ' + ERROR_MESSAGE() AS Result;
    END CATCH
END
GO

/*==============================================================================
  sp_DeleteProfilePicture -- Returns: Result

  NEW. UserRepository.DeleteProfilePictureAsync has always called this name;
  nothing ever created it, so "remove photo" failed with "Could not find stored
  procedure". It is sp_UpdateProfilePicture with a NULL image, kept as its own
  entry point so the DELETE endpoint does not have to send a NULL VARBINARY(MAX).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.sp_DeleteProfilePicture
    @SchoolId   INT = NULL,
    @UserId     INT,
    @ModifiedBy INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_UpdateProfilePicture
        @SchoolId       = @SchoolId,
        @UserId         = @UserId,
        @ProfilePicture = NULL,
        @FileName       = NULL,
        @ContentType    = NULL,
        @ModifiedBy     = @ModifiedBy;
END
GO

PRINT '=== 14_Procs_Dashboard.sql complete ===';
GO

SET NOEXEC OFF;
GO
