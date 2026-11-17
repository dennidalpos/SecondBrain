#requires -Version 7.5
<#
.SYNOPSIS
Installs, removes and reports the resources-hook and trace-hook session hooks for Claude Code, Codex and Antigravity.
.DESCRIPTION
-Install / -Uninstall without -Apply print a preview and change nothing; with -Apply (and a Write session) the client
settings file is saved with a backup. Other entries are left untouched and the hooks grant no write permission.
-Status reports the state per client. memory-cycle-hook has no installer: it needs a per-turn permit.
.EXAMPLE
pwsh -NoProfile -File scripts/client-hooks.ps1 -Install -Client codex
pwsh -NoProfile -File scripts/client-hooks.ps1 -Install -Client codex -Apply -SessionId <id of a Write session>
#>
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [Parameter(Mandatory,ParameterSetName='Install')][switch]$Install,
    [Parameter(Mandatory,ParameterSetName='Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName='Status')][switch]$Status,
    [ValidateSet('claude-code','codex','antigravity')][string]$Client,
    [ValidateSet('resources-hook','trace-hook')][string[]]$Hook=@('resources-hook','trace-hook'),
    [Parameter(ParameterSetName='Install')][Parameter(ParameterSetName='Uninstall')][switch]$Apply,
    [string]$SettingsPath,
    [Parameter(ParameterSetName='Install')][Parameter(ParameterSetName='Uninstall')][string]$ConfigPath,
    [Parameter(ParameterSetName='Install')][Parameter(ParameterSetName='Uninstall')][string]$SessionId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
$brain=Get-SBBrainRootPath
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.ClientHooks.psm1') -Force
if($PSCmdlet.ParameterSetName -eq 'Status'){
    if($SettingsPath -and !$Client){throw (New-SBError 'clienthooks.client.required')}
    $clients=if($Client){@($Client)}else{@(Get-SBClientHookClients)}
    ConvertTo-SBJson @($clients|ForEach-Object {Get-SBClientHookStatus $brain $_ $SettingsPath})
    exit 0
}
if(!$Client){throw (New-SBError 'clienthooks.client.required')}
if(!$Apply){
    ConvertTo-SBJson (Set-SBClientHooks $brain (Join-Path $brain '.runtime/backups/client-hooks') $Client $SettingsPath $Hook -Remove:$Uninstall)
    exit 0
}
$config=Read-SBConfiguration $ConfigPath
$lock=Enter-SBOperation $config $SessionId
try{ConvertTo-SBJson (Set-SBClientHooks $brain $config.backupRoot $Client $SettingsPath $Hook -Remove:$Uninstall -Apply)}finally{Exit-SBOperation $lock}
