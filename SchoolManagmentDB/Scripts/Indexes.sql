/*==============================================================================
  Scripts/Indexes.sql
  Consolidated unique/nonclustered indexes from 01_Schema.sql.
  Note: each Tables/*.sql file also includes its indexes for standalone clarity.
  Prefer running Tables/*.sql (which already create these) OR this file — not both.
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
/* Filtered, because Subdomain is optional and many schools may have none. */
CREATE UNIQUE INDEX UX_Schools_Subdomain
    ON dbo.Schools (Subdomain)
    WHERE Subdomain IS NOT NULL;
GO

CREATE INDEX IX_RolePermissions_Role ON dbo.RolePermissions (RoleId) INCLUDE (ModuleName, CanView, CanCreate, CanEdit, CanDelete);
GO

/* Composite-FK target for Users.PersonId and Addresses.PersonId. */
CREATE UNIQUE INDEX UX_Persons_School_Id ON dbo.Persons (SchoolId, Id);
GO

CREATE INDEX IX_Persons_School_Name ON dbo.Persons (SchoolId, LastName, FirstName) INCLUDE (IsActive);
GO

/* Composite-FK target. Nullable SchoolId is fine: child SchoolId is NOT NULL,
   so a tenant row can never match the SuperAdmin's NULL. */
CREATE UNIQUE INDEX UX_Users_School_Id ON dbo.Users (SchoolId, Id);
GO

CREATE INDEX IX_Users_School_Role       ON dbo.Users (SchoolId, RoleId) INCLUDE (IsActive);
CREATE INDEX IX_Users_Username          ON dbo.Users (Username);
CREATE INDEX IX_Users_School_Email      ON dbo.Users (SchoolId, Email);
CREATE INDEX IX_Users_PersonId          ON dbo.Users (PersonId);
GO

/* At most one primary address per person, so vw_Users.Address is deterministic. */
CREATE UNIQUE INDEX UX_Addresses_Person_Primary
    ON dbo.Addresses (PersonId)
    WHERE IsPrimary = 1;
GO

CREATE INDEX IX_Addresses_Person ON dbo.Addresses (PersonId) INCLUDE (IsActive, IsPrimary);
GO

CREATE UNIQUE INDEX UX_Teachers_School_Id ON dbo.Teachers (SchoolId, Id);
CREATE INDEX IX_Teachers_School_IsActive  ON dbo.Teachers (SchoolId, IsActive);
GO

CREATE UNIQUE INDEX UX_Classes_School_Id ON dbo.Classes (SchoolId, Id);
CREATE INDEX IX_Classes_School_IsActive  ON dbo.Classes (SchoolId, IsActive);
GO

CREATE UNIQUE INDEX UX_Students_School_Id  ON dbo.Students (SchoolId, Id);
CREATE INDEX IX_Students_School_Class      ON dbo.Students (SchoolId, ClassId) INCLUDE (IsActive, RollNumber);
CREATE INDEX IX_Students_School_StudentId  ON dbo.Students (SchoolId, StudentId);
GO

/* Roll numbers are unique within a class, but only where one is assigned. */
CREATE UNIQUE INDEX UX_Students_School_Class_Roll
    ON dbo.Students (SchoolId, ClassId, RollNumber)
    WHERE ClassId IS NOT NULL AND RollNumber IS NOT NULL;
GO

CREATE UNIQUE INDEX UX_Parents_School_Id ON dbo.Parents (SchoolId, Id);
GO

CREATE INDEX IX_StudentParents_School_Parent ON dbo.StudentParents (SchoolId, ParentId);
GO

CREATE UNIQUE INDEX UX_Subjects_School_Id ON dbo.Subjects (SchoolId, Id);
CREATE INDEX IX_Subjects_School_Grade     ON dbo.Subjects (SchoolId, Grade) INCLUDE (IsActive);
GO

CREATE INDEX IX_StudentSubjects_School_Subject ON dbo.StudentSubjects (SchoolId, SubjectId);
GO

CREATE INDEX IX_TeacherSubjects_School_Subject ON dbo.TeacherSubjects (SchoolId, SubjectId);
GO

CREATE INDEX IX_TSA_School_Teacher ON dbo.TeacherSubjectAssignments (SchoolId, TeacherId) INCLUDE (IsActive);
CREATE INDEX IX_TSA_School_Class   ON dbo.TeacherSubjectAssignments (SchoolId, ClassId);
GO

CREATE INDEX IX_TeacherSchedule_School_Teacher_Day
    ON dbo.TeacherSchedule (SchoolId, TeacherId, DayOfWeek, StartTime) INCLUDE (IsActive);
CREATE INDEX IX_TeacherSchedule_School_Class_Day
    ON dbo.TeacherSchedule (SchoolId, ClassId, DayOfWeek, StartTime);
GO

CREATE INDEX IX_TeacherSchedule_School_Teacher_Day
    ON dbo.TeacherSchedule (SchoolId, TeacherId, DayOfWeek, StartTime) INCLUDE (IsActive);
CREATE INDEX IX_TeacherSchedule_School_Class_Day
    ON dbo.TeacherSchedule (SchoolId, ClassId, DayOfWeek, StartTime);
GO

CREATE INDEX IX_Attendance_School_Class_Date
    ON dbo.Attendance (SchoolId, ClassId, AttendanceDate) INCLUDE (IsPresent, StudentId);
CREATE INDEX IX_Attendance_School_Date
    ON dbo.Attendance (SchoolId, AttendanceDate) INCLUDE (IsPresent);
GO

CREATE UNIQUE INDEX UX_Examinations_School_Id ON dbo.Examinations (SchoolId, Id);
CREATE INDEX IX_Examinations_School_Class_Subject
    ON dbo.Examinations (SchoolId, ClassId, SubjectId) INCLUDE (IsActive, ExamDate);
GO

CREATE INDEX IX_Results_School_Exam ON dbo.Results (SchoolId, ExaminationId) INCLUDE (StudentId, ObtainedMarks);
GO

CREATE UNIQUE INDEX UX_FeeTypes_School_Id ON dbo.FeeTypes (SchoolId, Id);
GO

CREATE UNIQUE INDEX UX_Fees_School_Id ON dbo.Fees (SchoolId, Id);
CREATE INDEX IX_Fees_School_Student   ON dbo.Fees (SchoolId, StudentId) INCLUDE (IsActive, Amount, DueDate);
CREATE INDEX IX_Fees_School_DueDate   ON dbo.Fees (SchoolId, DueDate)   INCLUDE (IsActive, Amount, StudentId);
GO

/* One fee row per student / type / period. Stops the same monthly fee being
   raised twice, which the old schema allowed. */
CREATE UNIQUE INDEX UX_Fees_School_Student_Type_Period
    ON dbo.Fees (SchoolId, StudentId, FeeTypeId, FeeYear, FeeMonth);
GO

CREATE INDEX IX_FeePayments_School_Fee ON dbo.FeePayments (SchoolId, FeeId) INCLUDE (AmountPaid, PaymentStatus);
GO

CREATE UNIQUE INDEX UX_FeePayments_School_Receipt
    ON dbo.FeePayments (SchoolId, ReceiptNumber)
    WHERE ReceiptNumber IS NOT NULL;
GO

CREATE INDEX IX_Settings_School_Category ON dbo.Settings (SchoolId, Category) INCLUDE (SettingKey, SettingValue);
GO

CREATE INDEX IX_RefreshTokens_UserId     ON dbo.RefreshTokens (UserId) INCLUDE (IsActive, ExpiryDate);
CREATE INDEX IX_RefreshTokens_ExpiryDate ON dbo.RefreshTokens (ExpiryDate);
GO

CREATE INDEX IX_AuditLog_School_Created ON dbo.AuditLog (SchoolId, CreatedAt DESC);
CREATE INDEX IX_AuditLog_User_Created   ON dbo.AuditLog (UserId, CreatedAt DESC);
GO

SET NOEXEC OFF;
GO

