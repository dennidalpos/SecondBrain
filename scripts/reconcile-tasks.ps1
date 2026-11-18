#requires -Version 7.5
<#
.SYNOPSIS
sb reconcile tasks: verify and reconcile conflicting or invalid queued writes and orphan receipts of one repository.
.DESCRIPTION
Plan only by default: lists every conflict, invalid request and orphan receipt with its class, whether it is safe, and the options.
-Apply executes the safe classes: already-applied requests and orphan receipts are retired (moved to .runtime/access/pending-discarded
with a note, never deleted), and stale requests that only add data are re-planned against the current state.
-Decide <request id>=<option> executes the user's choice for any item (retire, replan, cancel-task, retire-receipt, keep).
Removing a task means status cancelled, never a deletion. New requests made by a re-plan are integrated by knowledge.ps1 -FlushPending.
.EXAMPLE
pwsh -NoProfile -File scripts/reconcile-tasks.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/reconcile-tasks.ps1 -Apply
.EXAMPLE
pwsh -NoProfile -File scripts/reconcile-tasks.ps1 -Decide 0123456789abcdef0123456789abcdef=retire
#>
[CmdletBinding()]
param([string]$Repository,[string]$CheckoutPath,[switch]$All,[switch]$Apply,[string[]]$Decide=@(),[string]$ConfigPath,[string]$SessionId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Reconcile.psm1')
Add-SBMessages @{
    'reconcilecli.scope' = @{ en = 'Repository not resolvable: run from the checkout, give -Repository or -CheckoutPath, or use -All to plan every repository (read-only)' }
    'reconcilecli.all.write' = @{ en = '-All only plans: name -Repository to apply or decide' }
}
# With -File a list arrives as one comma-separated string.
$Decide=@($Decide|ForEach-Object {$_ -split ','}|ForEach-Object {$_.Trim()}|Where-Object {$_})
$decisions=@{}
foreach($entry in $Decide){
    $pair=$entry -split '=',2
    if($pair.Count -ne 2 -or $pair[0] -cnotmatch '^[a-f0-9]{32}$' -or !$pair[1].Trim()){[Console]::Error.WriteLine((Get-SBMessage 'reconcile.decide.invalid' @($entry)));exit 2}
    $decisions[$pair[0]]=$pair[1].Trim()
}
$lock=$null
try{
    $brain=(Get-SBBrainRootPath)
    $write=($Apply -or $decisions.Count -gt 0)
    if($All -and $write){throw (New-SBError 'reconcilecli.all.write')}
    $scopeRepository=$null;$writeScope=''
    if(!$All){
        $probe=Read-SBConfiguration $ConfigPath -ReadOnly
        $scopeRepository=if($Repository){$Repository}else{try{Resolve-SBWorkingRepository $CheckoutPath @($probe.bindings)}catch{$null}}
        if(!$scopeRepository){throw (New-SBError 'reconcilecli.scope')}
        $writeScope=Get-SBScopeKey $scopeRepository
    }
    $config=Read-SBConfiguration $ConfigPath -ReadOnly:(!$write) -Scope $writeScope
    $lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$write) -Scope $writeScope
    $result=Invoke-SBReconcile -BrainRoot $brain -Config $config -Repository $scopeRepository -Apply:$Apply -Decisions $decisions -SessionId $SessionId
    ConvertTo-SBJson $result
    if(@($result.failed).Count){exit 1}
    exit 0
}catch{
    if(Test-SBWriteDeniedError $_){Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters;exit 4}
    if(Test-SBBusyError $_){[Console]::Error.WriteLine($_.Exception.Message);exit 3}
    Write-Error $_ -ErrorAction Continue;exit 2
}finally{Exit-SBOperation $lock}
