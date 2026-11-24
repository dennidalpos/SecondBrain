#requires -Version 7.5
<#
.SYNOPSIS
Migrates the repository bindings of the workstation configuration to the minimal form (#700).
.DESCRIPTION
A binding keeps identity, path and managed block hash. repositoryFiles (only when it is not the default list), remoteIdentity (only when it
differs from the identity) and status (only when it is not managed) stay when they carry information; fingerprint and dossier are dropped
(the repository identity identifies the dossier, the origin guard derives from the identity). Old and minimal bindings work side by side.
Without -Apply it only previews. -Apply backs up the previous configuration and rewrites it; repeating it changes nothing.
Exit code: 0 done or unchanged, 2 error, 3 busy, 4 write denied.
.EXAMPLE
pwsh -NoProfile -File scripts/bindings.ps1 -MigrateBindings
pwsh -NoProfile -File scripts/bindings.ps1 -MigrateBindings -Apply
#>
[CmdletBinding()]
param([Parameter(Mandatory)][switch]$MigrateBindings,[switch]$Apply,[string]$ConfigPath,[string]$SessionId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Bindings.psm1')
$lock=$null
try{
    $brain=(Get-SBBrainRootPath)
    $config=Read-SBConfiguration $ConfigPath -ReadOnly:(!$Apply)
    $lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)
    $result=Invoke-SBBindingMigration -BrainRoot $brain -ConfigPath $config.configPath -BackupRoot $config.localStateBackupRoot -Apply:$Apply
    ConvertTo-SBJson $result
    exit 0
}catch{
    if(Test-SBWriteDeniedError $_){Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters;exit 4}
    if(Test-SBBusyError $_){[Console]::Error.WriteLine($_.Exception.Message);exit 3}
    Write-Error $_ -ErrorAction Continue;exit 2
}finally{Exit-SBOperation $lock}
