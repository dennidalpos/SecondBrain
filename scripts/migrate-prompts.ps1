#requires -Version 7.5
<#
.SYNOPSIS
Applies the approved prompt migration map (direttive/prompts/migration-map.json) to the catalog.
.DESCRIPTION
Preview by default: lists every old code with its outcome (rename, retire into a workflow), whether the old card ID is kept or retired,
the work still waiting for new cards or workflows, and the file changes. -Apply renames cards (git mv inside a checkout), removes the
cards that became workflows (the text stays in Git), rewrites old-code citations in the surviving cards, writes aliases.json and
regenerates the indexes. A second run finds nothing to change. Use -SessionId in Write sessions.
.EXAMPLE
pwsh -NoProfile -File scripts/migrate-prompts.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/migrate-prompts.ps1 -Apply
#>
[CmdletBinding()]
param([string]$ConfigPath,[string]$SessionId,[switch]$Apply)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptMigration.psm1') -Force
$config=$null;$lock=$null
try{$config=Read-SBConfiguration $ConfigPath}catch{if($Apply){throw}}
if($config){$lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)}
try {
    $brain=Get-SBBrainRootPath
    $plan=Get-SBPromptMigrationPlan $brain
    Format-SBPromptMigrationPlan $plan
    if(!$Apply){exit 0}
    if(!$plan.changeCount){Get-SBMessage 'prompts.migration.clean';exit 0}
    $inGit=Test-Path -LiteralPath (Join-Path $brain '.git')
    $write={param($path,$text) Write-SBFile $path ([Text.UTF8Encoding]::new($false).GetBytes($text)) (Get-SBFileHash $path) $config.backupRoot -BackupDirty | Out-Null}
    $move={param($from,$to) if($inGit){& git -C $brain mv -- $from $to;if($LASTEXITCODE){throw (New-SBError 'prompts.migration.invalid' @($to))}}else{Move-Item -LiteralPath $from -Destination $to}}
    $remove={param($path) if($inGit){& git -C $brain rm -q -- $path;if($LASTEXITCODE){throw (New-SBError 'prompts.migration.invalid' @($path))}}else{Remove-Item -LiteralPath $path}}
    Invoke-SBPromptMigration $plan $write $move $remove
    # Regenerate the indexes the way build-prompts.ps1 does.
    foreach($item in @(Get-SBWorkflowDrift $brain)){
        $path=Join-Path $brain $item.path
        Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes($item.text)) (Get-SBFileHash $path) $config.backupRoot -BackupDirty | Out-Null
    }
    Get-SBMessage 'prompts.migration.applied' @($plan.changeCount)
    exit 0
}finally{if($lock){Exit-SBOperation $lock}}
