<#
.SYNOPSIS
  Deploys SchoolManagementDB from the structured folder layout.

.EXAMPLE
  .\Scripts\Deploy.ps1 -ServerInstance ".\SQLEXPRESS" -Database "SchoolManagementDB"
  .\Scripts\Deploy.ps1 -ServerInstance ".\SQLEXPRESS" -Database "SchoolManagementDB" -IncludeSeed -IncludeVerify
  .\Scripts\Deploy.ps1 -ServerInstance ".\SQLEXPRESS" -Database "SchoolManagementDB" -DropFirst
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ServerInstance,

  [string]$Database = 'SchoolManagementDB',

  [switch]$DropFirst,
  [switch]$IncludeSeed,
  [switch]$IncludeVerify,
  [switch]$TrustedConnection = $true
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $root 'Tables'))) {
  $root = $PSScriptRoot
  if (-not (Test-Path (Join-Path $root 'Tables'))) {
    throw "Cannot locate SchoolManagementDB root (expected Tables/ next to Scripts/)."
  }
}

function Invoke-SqlFile([string]$Path) {
  if (-not (Test-Path $Path)) { throw "Missing script: $Path" }
  $rel = $Path
  if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $Path.Substring($root.Length).TrimStart('\')
  }
  Write-Host ">> $rel" -ForegroundColor Cyan
  & sqlcmd -S $ServerInstance -d $Database -E -b -I -i $Path
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE) on $Path" }
}

# 1) Ensure database exists (runs without -d against master)
Write-Host "Ensuring database exists..." -ForegroundColor Yellow
& sqlcmd -S $ServerInstance -E -b -I -i (Join-Path $root 'Scripts\DatabaseCreation.sql')
if ($LASTEXITCODE -ne 0) { throw "DatabaseCreation failed" }

if ($DropFirst) {
  Invoke-SqlFile (Join-Path $root 'Scripts\DropAll.sql')
}

Invoke-SqlFile (Join-Path $root 'Scripts\DatabaseConfiguration.sql')

# Table deploy order (FK dependencies)
$tableOrder = @(
  'Schools','SchoolSequences','Roles','RolePermissions','Persons','Users','Addresses',
  'Teachers','Classes','Students','Parents','StudentParents','Subjects','StudentSubjects',
  'TeacherSubjects','TeacherSubjectAssignments','TeacherSchedule','Attendance',
  'Examinations','Results','FeeTypes','Fees','FeePayments','Settings','RefreshTokens','AuditLog'
)

Write-Host "`n=== Tables ===" -ForegroundColor Yellow
foreach ($t in $tableOrder) {
  Invoke-SqlFile (Join-Path $root "Tables\$t.sql")
}

Write-Host "`n=== Deferred FKs ===" -ForegroundColor Yellow
Invoke-SqlFile (Join-Path $root 'Scripts\ForeignKeys.sql')

Write-Host "`n=== Views ===" -ForegroundColor Yellow
Get-ChildItem (Join-Path $root 'Views\*.sql') | Sort-Object Name | ForEach-Object { Invoke-SqlFile $_.FullName }

Write-Host "`n=== Functions ===" -ForegroundColor Yellow
# SanitizeCode first (others depend on it)
$fnOrder = @(
  'fn_SanitizeCode','fn_GenerateStudentId','fn_GenerateStudentUsername',
  'fn_GenerateTeacherUsername','fn_GenerateTeacherEmployeeId','fn_GenerateParentUsername',
  'fn_GenerateReceiptNumber','fn_CalculateGrade','fn_DayName','fn_SchoolCode',
  'fn_AcademicYear','fn_RoleId','fn_RoleName'
)
foreach ($f in $fnOrder) {
  Invoke-SqlFile (Join-Path $root "Functions\$f.sql")
}

Write-Host "`n=== Stored Procedures ===" -ForegroundColor Yellow
# Helpers first, then the rest alphabetically is fine (CREATE OR ALTER)
$helperFirst = @(
  'sp_NextSequence','sp_PeekSequence','sp_AssertSchool','sp_LogAudit',
  'sp_ResolveRole','sp_UpsertPerson','sp_UpsertAddress',
  'sp_CreateUserAccount','sp_UpdateUserIdentity','sp_GetTeacherByUserId'
)
foreach ($h in $helperFirst) {
  Invoke-SqlFile (Join-Path $root "StoredProcedures\$h.sql")
}
Get-ChildItem (Join-Path $root 'StoredProcedures\*.sql') |
  Where-Object { $helperFirst -notcontains $_.BaseName } |
  Sort-Object Name |
  ForEach-Object { Invoke-SqlFile $_.FullName }

Write-Host "`n=== Reference seed (Roles) ===" -ForegroundColor Yellow
Invoke-SqlFile (Join-Path $root 'SeedData\Roles.sql')
Invoke-SqlFile (Join-Path $root 'SeedData\RolePermissions.sql')

if ($IncludeSeed) {
  Write-Host "`n=== Demo seed ===" -ForegroundColor Yellow
  Invoke-SqlFile (Join-Path $root 'SeedData\InitialData.sql')
}

if ($IncludeVerify) {
  Write-Host "`n=== Verify ===" -ForegroundColor Yellow
  Invoke-SqlFile (Join-Path $root 'Scripts\Verify.sql')
}

Write-Host "`nDeploy complete." -ForegroundColor Green