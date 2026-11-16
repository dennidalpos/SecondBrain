#requires -Version 7.5
<#
.SYNOPSIS
Analyzes a project, proposes useful skills and installs the selected ones for Claude Code, Codex and Antigravity.
.DESCRIPTION
-Analyze is read-only: it prints the detected facts, the proposed skills with the reason for each, and the skill folders of every client.
-Install previews by default and changes nothing. With -Apply it writes <skill>/SKILL.md under the client's folder, project scope (inside the checkout)
or user scope (inside the home folder), through Write-SBFile with a backup. A skill that already exists with different content is a conflict and is skipped
unless -Overwrite is given. Folders come from the official documentation (checked 2026-11-15); liveVerified stays false until a session shows the skill loaded.
Exit: 0 ok, 1 conflicts skipped, 2 error, 3 writer busy, 4 write denied.
.EXAMPLE
pwsh -NoProfile -File scripts/skills.ps1 -Analyze -CheckoutPath <project-folder>
pwsh -NoProfile -File scripts/skills.ps1 -Install -CheckoutPath <project-folder> -Select project-checks,repo-map -Client claude-code,codex -Scope project -Apply
#>
[CmdletBinding()]
param(
    [switch]$Analyze,
    [switch]$Install,
    [string]$CheckoutPath='.',
    [string[]]$Select=@(),
    [string[]]$Client=@('claude-code','codex','antigravity'),
    [ValidateSet('project','user')][string]$Scope='project',
    [string]$HomeRoot,
    [string]$ConfigPath,
    [string]$SessionId,
    [switch]$Overwrite,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; Write-Error $_ -ErrorAction Continue; exit 2 }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Skills.psm1') -Force
Add-SBMessages @{
    'skills.cli.mode' = @{ en = 'Give one of -Analyze or -Install' }
}
if (($Analyze.IsPresent -eq $Install.IsPresent)) { throw (New-SBError 'skills.cli.mode') }
$Client = @($Client | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Select = @($Select | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($c in $Client) { if ($c -notin (Get-SBSkillClients)) { throw (New-SBError 'skills.client.invalid' @($c)) } }
$checkout = [IO.Path]::GetFullPath($CheckoutPath)
if (!(Test-Path -LiteralPath $checkout -PathType Container)) { throw (New-SBError 'skills.checkout.missing' @($checkout)) }

$facts = Get-SBProjectFacts $checkout
$proposals = @(Get-SBSkillProposals $facts)
if ($Analyze) {
    return ConvertTo-SBJson @{
        facts = $facts
        proposals = @($proposals | ForEach-Object { [ordered]@{ name = $_.name; reason = $_.reason; description = $_.description } })
        clients = @(Get-SBSkillClientInfo)
    }
}

$plan = @(New-SBSkillInstallPlan $proposals $Select $Client $Scope $checkout $HomeRoot)
$view = @($plan | ForEach-Object { [ordered]@{ client = $_.client; scope = $_.scope; skill = $_.skill; file = $_.file; state = $_.state } })
$conflicts = @($plan | Where-Object { $_.state -eq 'conflict' }).Count
if (!$Apply) {
    return ConvertTo-SBJson @{ apply = $false; scope = $Scope; items = $view; conflicts = $conflicts; liveVerified = $false }
}
$config = Read-SBConfiguration $ConfigPath
$operation = Enter-SBOperation $config $SessionId -LockOnly
try {
    $written = @(); $skipped = @()
    foreach ($item in $plan) {
        if ($item.state -in @('unchanged', 'shared')) { continue }
        if ($item.state -eq 'conflict' -and !$Overwrite) { $skipped += $item.file; continue }
        Write-SBFile $item.file $item.bytes $item.expected $config.localStateBackupRoot -BackupDirty | Out-Null
        $written += $item.file
    }
    ConvertTo-SBJson @{ apply = $true; scope = $Scope; written = @($written); skippedConflicts = @($skipped); liveVerified = $false }
    if ($skipped.Count) { exit 1 }
} finally { Exit-SBOperation $operation }
