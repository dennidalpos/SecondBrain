#requires -Version 7.5
<#
.SYNOPSIS
sb resync: realigns a repository that was edited outside SecondBrain or not opened for a long time.
.DESCRIPTION
Compares Git state, managed blocks, tracker and dossier (the repository-scoped `secondbrain.ps1 -Check`), prints a plan, and for every conflict says what to do in the repository or which prompt to run.
Nothing is written without -Apply. -Apply runs `secondbrain.ps1 -Sync` for the repository (managed blocks and generated views only; conflicts are preserved) and then re-checks.
.EXAMPLE
pwsh -NoProfile -File scripts/resync.ps1 -RepositoryIdentity github.com/my-org/my-project
.EXAMPLE
pwsh -NoProfile -File scripts/resync.ps1 -RepositoryIdentity github.com/my-org/my-project -Apply
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RepositoryIdentity,[switch]$Apply,[string]$ConfigPath,[string]$SessionId)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Resync.psm1')
function Invoke-ResyncCheck {
    $arguments=@('-Check','-Repository',$RepositoryIdentity)
    if($ConfigPath){$arguments+=@('-ConfigPath',$ConfigPath)}
    $raw=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'secondbrain.ps1') @arguments 2>&1|Out-String
    $start=$raw.IndexOf('{');if($start -lt 0){throw $raw.Trim()}
    ConvertFrom-Json -InputObject $raw.Substring($start) -AsHashtable
}
$result=Invoke-ResyncCheck
$plan=Get-SBResyncPlan -Findings @(@($result.issues)+@($result.warnings)) -Repository $RepositoryIdentity
$plan.applied=$false
if($Apply -and $plan.safeCount){
    $arguments=@('-Sync','-Repository',$RepositoryIdentity)
    if($ConfigPath){$arguments+=@('-ConfigPath',$ConfigPath)}
    if($SessionId){$arguments+=@('-SessionId',$SessionId)}
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'secondbrain.ps1') @arguments | Out-Null
    $again=Invoke-ResyncCheck
    $plan=Get-SBResyncPlan -Findings @(@($again.issues)+@($again.warnings)) -Repository $RepositoryIdentity
    $plan.applied=$true
}
ConvertTo-SBJson $plan
exit $(if($plan.status -eq 'needs-decision'){2}else{0})
