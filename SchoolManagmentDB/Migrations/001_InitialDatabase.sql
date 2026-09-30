/*==============================================================================
  Migrations/001_InitialDatabase.sql
  ------------------------------------------------------------------------------
  Marker migration for the structured SchoolManagementDB layout.

  The initial schema is applied by Scripts/Deploy.ps1 (Tables → FKs → Views →
  Functions → StoredProcedures → SeedData/Roles + RolePermissions).

  Subsequent schema changes go in 002_*.sql, 003_*.sql, etc. Prefer additive
  ALTER scripts here rather than editing historical numbered files under _legacy/.
==============================================================================*/

PRINT '001_InitialDatabase: use Scripts/Deploy.ps1 for the full initial apply.';
GO