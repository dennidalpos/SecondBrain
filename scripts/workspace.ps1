#requires -Version 7.5
<#
.SYNOPSIS
Registers and inspects personal workspaces: folders without Git, with a private dossier and an explicit output scope.
.DESCRIPTION
Without -Apply, -Register previews only and changes nothing. Registration never creates .git, never writes inside the workspace folder,
and keeps SecondBrain state outside it. A workspace starts read-only; -OutputScope lists the subfolders where writes are permitted.
-List shows the registered workspaces. -AssertWrite <path> exits 4 when the path is outside the permitted output scope.
.EXAMPLE
pwsh -NoProfile -File scripts/workspace.ps1 -Register -Path "D:\Notes\Personal" -OutputScope "exports" -Apply
#>
[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$List,
    [string]$AssertWrite,
    [string]$Path,
    [string]$Name,
    [string[]]$OutputScope = @(),
    [string]$BrainRoot,
    [string]$ConfigPath,
    [string]$SessionId,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$brain = if ($BrainRoot) { [IO.Path]::GetFullPath($BrainRoot) } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Workspace.psm1') -Force
Add-SBMessages @{
    'workspace.cli.mode' = @{ en = 'Give one of -Register, -List or -AssertWrite' }
    'workspace.cli.path' = @{ en = '-Register needs -Path' }
    'workspace.cli.refused' = @{ en = 'Write refused: {0}' }
}

$modes = @($Register.IsPresent, $List.IsPresent, [bool]$AssertWrite).Where({ $_ }).Count
if ($modes -ne 1) { throw (New-SBError 'workspace.cli.mode') }
if ($Register -and !$Path) { throw (New-SBError 'workspace.cli.path') }

$readOnly = !($Register -and $Apply)
$config = Read-SBConfiguration $ConfigPath -ReadOnly:$readOnly
$workstationConfigPath = $config.configPath
$workstation = Read-SBJson $workstationConfigPath @{}

if ($List) {
    return ConvertTo-SBJson @{ workspaces = @(Get-SBWorkspaceEntries $workstation) }
}
if ($AssertWrite) {
    $entry = Find-SBWorkspaceFor $workstation $AssertWrite
    if (!$entry) { return ConvertTo-SBJson @{ workspace = $false; allowed = $true } }
    try { [void](Assert-SBWorkspaceWrite $entry $AssertWrite) }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 4 }
    return ConvertTo-SBJson @{ workspace = $true; allowed = $true; identity = $entry.identity }
}

$plan = New-SBWorkspacePlan $brain $workstation $Path $Name $OutputScope @($config.localStateRoot, $config.runtimeRoot, $config.backupRoot)
if (!$Apply) {
    return ConvertTo-SBJson @{ apply = $false; plan = $plan }
}
$operation = Enter-SBOperation $config $SessionId
try {
    $entry = Register-SBWorkspace $config $workstationConfigPath $plan $config.localStateBackupRoot
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1') -Force
    Update-SBParaIndex $config | Out-Null
    ConvertTo-SBJson @{ apply = $true; workspace = $entry }
} finally { Exit-SBOperation $operation }
