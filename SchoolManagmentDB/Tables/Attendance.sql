/*==============================================================================
  Table : dbo.Attendance
  Extracted from: 01_Schema.sql
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
/*------------------------------------------------------------------------------
  TeacherSchedule -- weekly timetable.
------------------------------------------------------------------------------*/
CREATE TABLE dbo.TeacherSchedule (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    TeacherId       INT                             NOT NULL,   -- Teachers.Id
    SubjectId       INT                             NOT NULL,
    ClassId         INT                             NOT NULL,
    DayOfWeek       INT                             NOT NULL,   -- 1=Monday .. 7=Sunday
    StartTime       TIME(0)                         NOT NULL,
    EndTime         TIME(0)                         NOT NULL,
    Room            NVARCHAR(50)                    NULL,
    IsActive        BIT                             NOT NULL
        CONSTRAINT DF_TeacherSchedule_IsActive DEFAULT (1),
    CreatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSchedule_CreatedAt DEFAULT (GETDATE()),
    UpdatedAt       DATETIME                        NOT NULL
        CONSTRAINT DF_TeacherSchedule_UpdatedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_TeacherSchedule PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT FK_TeacherSchedule_School  FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_TeacherSchedule_Teacher FOREIGN KEY (SchoolId, TeacherId) REFERENCES dbo.Teachers (SchoolId, Id),
    CONSTRAINT FK_TeacherSchedule_Subject FOREIGN KEY (SchoolId, SubjectId) REFERENCES dbo.Subjects (SchoolId, Id),
    CONSTRAINT FK_TeacherSchedule_Class   FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT CK_TeacherSchedule_DayOfWeek CHECK (DayOfWeek BETWEEN 1 AND 7)
);
GO
CREATE INDEX IX_TeacherSchedule_School_Teacher_Day
    ON dbo.TeacherSchedule (SchoolId, TeacherId, DayOfWeek, StartTime) INCLUDE (IsActive);
CREATE INDEX IX_TeacherSchedule_School_Class_Day
    ON dbo.TeacherSchedule (SchoolId, ClassId, DayOfWeek, StartTime);
GO

/*==============================================================================
  SECTION 4 -- ATTENDANCE
==============================================================================*/

CREATE TABLE dbo.Attendance (
    Id              INT             IDENTITY(1,1)   NOT NULL,
    SchoolId        INT                             NOT NULL,
    StudentId       INT                             NOT NULL,   -- Students.Id
    ClassId         INT                             NOT NULL,
    AttendanceDate  DATE                            NOT NULL,
    IsPresent       BIT                             NOT NULL,
    Remarks         NVARCHAR(255)                   NULL,
    MarkedBy        INT                             NOT NULL,   -- Users.Id
    MarkedAt        DATETIME                        NOT NULL
        CONSTRAINT DF_Attendance_MarkedAt DEFAULT (GETDATE()),

    CONSTRAINT PK_Attendance PRIMARY KEY CLUSTERED (Id),
    CONSTRAINT UQ_Attendance_Student_Date UNIQUE (SchoolId, StudentId, AttendanceDate),
    CONSTRAINT FK_Attendance_School   FOREIGN KEY (SchoolId) REFERENCES dbo.Schools (Id),
    CONSTRAINT FK_Attendance_Student  FOREIGN KEY (SchoolId, StudentId) REFERENCES dbo.Students (SchoolId, Id),
    CONSTRAINT FK_Attendance_Class    FOREIGN KEY (SchoolId, ClassId)   REFERENCES dbo.Classes  (SchoolId, Id),
    CONSTRAINT FK_Attendance_MarkedBy FOREIGN KEY (SchoolId, MarkedBy)  REFERENCES dbo.Users    (SchoolId, Id)
);
GO
CREATE INDEX IX_Attendance_School_Class_Date
    ON dbo.Attendance (SchoolId, ClassId, AttendanceDate) INCLUDE (IsPresent, StudentId);
CREATE INDEX IX_Attendance_School_Date
    ON dbo.Attendance (SchoolId, AttendanceDate) INCLUDE (IsPresent);
GO

/*==============================================================================
  SECTION 5 -- EXAMINATIONS AND RESULTS
==============================================================================*/

SET NOEXEC OFF;
GO

