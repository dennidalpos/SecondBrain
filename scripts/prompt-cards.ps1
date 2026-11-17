#requires -Version 7.5
<#
.SYNOPSIS
Card lifecycle: add, edit, duplicate, deprecate and retire prompt cards through validated operations.
.DESCRIPTION
Preview by default: shows the planned changes and validates them on a temporary copy of the catalog. -Apply writes the cards,
the catalog, aliases.json (retire) and regenerates the indexes. Retiring a card that is still referenced is refused and names
every reference (related lists, citations, workflow steps, role). Use -SessionId in Write sessions.
.EXAMPLE
pwsh -NoProfile -File scripts/prompt-cards.ps1 -Operation retire -Card pmt-0123abcd
.EXAMPLE
pwsh -NoProfile -File scripts/prompt-cards.ps1 -Operation deprecate -Card pmt-0123abcd -Reason 'Replaced by a workflow' -Successor pmt-4567ef01 -Apply
.EXAMPLE
pwsh -NoProfile -File scripts/prompt-cards.ps1 -Operation duplicate -Card pmt-0123abcd -NewCode ZZZ93 -Summary 'Run a short audit'
.EXAMPLE
pwsh -NoProfile -File scripts/prompt-cards.ps1 -Operation edit -Card pmt-0123abcd -Field @{summary='New summary.'} -BodyPath card.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('add','edit','duplicate','deprecate','retire')][string]$Operation,
    [string]$Card,[string]$NewCode,[string]$Summary,[string]$Reason,[string]$Successor,
    [string]$Category,[string]$Target,[string]$Mode,[string]$Scope,[string]$Requires,[string]$Example,
    [string]$Role,[string[]]$Related,[switch]$Destructive,[hashtable]$Field,
    [string]$BodyPath,
    [string]$ConfigPath,[string]$SessionId,[switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptMigration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptLifecycle.psm1') -Force
$config=$null;$lock=$null
try{$config=Read-SBConfiguration $ConfigPath}catch{if($Apply){throw}}
if($config){$lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)}
try {
    $brain=Get-SBBrainRootPath
    $options=@{Code=$(if($Operation -eq 'add'){$NewCode}else{$Card});NewCode=$NewCode;Summary=$Summary;Reason=$Reason;Successor=$Successor
        Category=$Category;Target=$Target;Mode=$Mode;Scope=$Scope;Requires=$Requires;Example=$Example
        Role=$Role;Related=$Related;Destructive=[bool]$Destructive;Fields=$Field;BodyPath=$BodyPath}
    $plan=Get-SBPromptLifecyclePlan $brain $Operation $options
    Format-SBPromptLifecyclePlan $plan
    if(!$plan.valid){exit 2}
    if(!$Apply){exit 0}
    $write={param($path,$text) [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null; Write-SBFile $path ([Text.UTF8Encoding]::new($false).GetBytes($text)) (Get-SBFileHash $path) $config.backupRoot -BackupDirty | Out-Null}
    $inGit=Test-Path -LiteralPath (Join-Path $brain '.git')
    $remove={param($path) if($inGit){& git -C $brain rm -q -- $path;if($LASTEXITCODE){throw (New-SBError 'prompts.lifecycle.refused' @($path))}}else{Remove-Item -LiteralPath $path}}
    Invoke-SBPromptLifecycle $brain $plan $write $remove
    foreach($item in @(Get-SBWorkflowDrift $brain)){
        $path=Join-Path $brain $item.path
        Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes($item.text)) (Get-SBFileHash $path) $config.backupRoot -BackupDirty | Out-Null
    }
    Get-SBMessage 'prompts.lifecycle.applied' @($Operation,$plan.subject,$plan.changeCount)
    exit 0
}finally{if($lock){Exit-SBOperation $lock}}
