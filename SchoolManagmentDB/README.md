# SchoolManagementDB

Structured SQL Server project for the multi-tenant School Management system.

**One database, one API, one URL, many schools.**

| Folder | Count | Contents |
|---|---:|---|
| `Tables/` | 26 | One `CREATE TABLE` (+ its indexes) per file |
| `StoredProcedures/` | 169 | One `CREATE OR ALTER PROCEDURE` per file |
| `Views/` | 1 | One view per file |
| `Functions/` | 13 | One `CREATE OR ALTER FUNCTION` per file |
| `SeedData/` | 3 | Reference roles + demo tenants |
| `Scripts/` | 7 | Create DB, FKs, deploy, drop, verify |
| `Migrations/` | 2 | Additive change scripts |

Legacy flat numbered scripts (`00_`…`17_`) are kept under `_legacy/` for reference only.

---

## Layout

```
SchoolManagementDB/          (this Database/ folder)
│
├── Tables/
│   ├── Schools.sql
│   ├── Users.sql
│   ├── Students.sql
│   ├── Teachers.sql
│   ├── Parents.sql
│   ├── Classes.sql
│   ├── Subjects.sql
│   ├── Attendance.sql
│   ├── Examinations.sql
│   ├── Results.sql
│   ├── Fees.sql
│   ├── FeePayments.sql
│   └── …
│
├── StoredProcedures/
│   ├── sp_RegisterStudent.sql
│   ├── sp_Login.sql
│   ├── sp_GetStudentById.sql
│   ├── sp_UpdateStudent.sql
│   ├── sp_DeleteStudent.sql
│   ├── sp_MarkAttendance.sql
│   ├── sp_MakeFeePayment.sql
│   └── …
│
├── Views/
│   └── vw_Users.sql
│
├── Functions/
│   ├── fn_GenerateStudentId.sql
│   ├── fn_CalculateGrade.sql
│   ├── fn_AcademicYear.sql
│   └── …
│
├── SeedData/
│   ├── Roles.sql                 # system roles (required)
│   ├── RolePermissions.sql       # default permission grid (required)
│   └── InitialData.sql           # demo schools — development only
│
├── Scripts/
│   ├── DatabaseCreation.sql
│   ├── DatabaseConfiguration.sql
│   ├── ForeignKeys.sql           # deferred audit FKs
│   ├── Indexes.sql               # consolidated index reference
│   ├── DropAll.sql
│   ├── Verify.sql
│   └── Deploy.ps1                # recommended apply path
│
├── Migrations/
│   ├── 001_InitialDatabase.sql
│   └── 002_Example_AddColumn.sql
│
├── _legacy/                      # former 00–17 flat scripts
├── README.md
└── .gitignore
```

---

## Deploy

### Recommended (PowerShell)

```powershell
cd Database

# Fresh schema + roles (no demo data)
.\Scripts\Deploy.ps1 -ServerInstance ".\SQLEXPRESS" -Database "SchoolManagementDB"

# Rebuild from scratch + demo seed + verify
.\Scripts\Deploy.ps1 -ServerInstance ".\SQLEXPRESS" -Database "SchoolManagementDB" `
  -DropFirst -IncludeSeed -IncludeVerify
```

Requires `sqlcmd` on `PATH` and a trusted Windows connection (`-E`).

### Apply order (what Deploy.ps1 does)

1. `Scripts/DatabaseCreation.sql` — create DB if missing
2. `Scripts/DropAll.sql` — only if `-DropFirst`
3. `Scripts/DatabaseConfiguration.sql`
4. `Tables/*.sql` — dependency order
5. `Scripts/ForeignKeys.sql` — deferred audit FKs
6. `Views/*.sql`
7. `Functions/*.sql`
8. `StoredProcedures/*.sql` — helpers first, then the rest
9. `SeedData/Roles.sql` + `SeedData/RolePermissions.sql`
10. `SeedData/InitialData.sql` — only if `-IncludeSeed`
11. `Scripts/Verify.sql` — only if `-IncludeVerify` (writes data; scratch DBs only)

> **Indexes:** each `Tables/*.sql` file already creates its indexes.  
> `Scripts/Indexes.sql` is a consolidated reference copy — do **not** run both on a fresh database.

### Re-running

- Procedures and functions are `CREATE OR ALTER` — safe to re-run individually.
- Tables are not idempotent; use `Scripts/DropAll.sql` (or `-DropFirst`) for a rebuild.
- `SeedData/Roles.sql` / `RolePermissions.sql` / `InitialData.sql` skip if already present.

---

## Conventions (unchanged)

1. **`@SchoolId INT` is the first parameter** on tenant procedures. The API passes it from the JWT `school_id` claim.
2. **Every tenant `FROM`/`JOIN` filters on `SchoolId`.**
3. **Every tenant `INSERT` writes `SchoolId`.**
4. **Composite FKs** on `(SchoolId, Id)` are the isolation safety net — do not remove them.

Platform exceptions: `sp_CreateSchool` and other platform procs; login/refresh keyed by username/token; profile procs may take `@SchoolId = NULL` for SuperAdmin.

---

## Demo credentials (`SeedData/InitialData.sql` only)

| Username | Role | Password |
|---|---|---|
| `superadmin` | SuperAdmin | `admin123` |
| `DPSNOIDA_ADMIN` | Admin | `admin123` |
| `STMARY_ADMIN` | Admin | `admin123` |
| seeded teachers / students | Teacher / Student | `Temp@123` |

Change these (or skip `-IncludeSeed`) before the database is reachable by anyone else.

---

## Adding objects

| Change | Where |
|---|---|
| New table | `Tables/YourTable.sql` + update table order in `Scripts/Deploy.ps1` |
| New procedure | `StoredProcedures/sp_YourProc.sql` |
| New function | `Functions/fn_YourFunc.sql` |
| New view | `Views/vw_YourView.sql` |
| Schema change on existing DB | `Migrations/00N_Description.sql` |

---

## Legacy

`_legacy/` holds the previous flat `00_Drop_All.sql` … `17_Procs_Parents.sql` scripts.  
Prefer the structured folders + `Scripts/Deploy.ps1` going forward.
