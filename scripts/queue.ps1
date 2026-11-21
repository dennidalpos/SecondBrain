#requires -Version 7.5
<#
.SYNOPSIS
Alternative entry point for the autonomous task queue (orchestrate-tasks.ps1), usable from any repository managed by SecondBrain.
.DESCRIPTION
Use it while maintenance tasks change the main runner (run-ready-tasks.ps1, SecondBrain.TaskRunner): the queue is independent of that runner.
Default is a preview: the selected and skipped tasks, nothing runs. The checkout is the Git root of -Checkout (default: the current directory).
  -Start   start the queue in a detached process on a queue/<date> branch (local commits only, never a push).
  -Status  show the latest queue run of the checkout (phase, pid alive, current task, counters, notice, last events).
  -Stop    ask the active queue run to end before the next task.
  -Candidates  read-only JSON of the open tasks the queue cannot take yet and what each lacks (-Limit N, -IncludeAdvisory, -NeedsOwner); input of the preparation flow (card role tasks.prepare).
The options below are forwarded unchanged to orchestrate-tasks.ps1; every other option of that script stays available by calling it directly (docs/orchestrate-tasks.md).
Exit codes: 0 done, 2 SecondBrain or the checkout not resolved, or the queue script failed to start.
#>
[CmdletBinding()]
param([string]$Checkout,[ValidateSet('claude','codex','gemini')][string]$Provider='claude',[string]$Model,[string]$Effort,
    [ValidateRange(0,1000)][int]$MaxTasks=0,[string[]]$OnlyIds=@(),[string[]]$ExcludeIds=@(),[string]$Branch,[string]$TrackerPath,
    [switch]$AllowNoPowerRequest,[switch]$Candidates,[switch]$IncludeAdvisory,[switch]$NeedsOwner,[ValidateRange(0,1000)][int]$Limit=0,[switch]$Start,[switch]$Status,[switch]$Stop)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'queue.exclusive' = @{ en = 'Use only one of -Start, -Status, -Stop and -Candidates' }
    'queue.checkout' = @{ en = 'Not inside a Git checkout: run it from a repository or pass -Checkout' }
    'queue.script' = @{ en = 'orchestrate-tasks.ps1 not found in {0}' }
    'queue.started' = @{ en = 'Queue started in a detached process (pid {0}) for {1}; follow it with `sb queue status`, end it with `sb queue stop`' }
}
try{
    if(@(@($Start,$Status,$Stop,$Candidates)|Where-Object {$_}).Count -gt 1){throw (New-SBError 'queue.exclusive')}
    $root=@($env:SECONDBRAIN_HOME,(Split-Path -Parent $PSScriptRoot))|Where-Object {$_ -and (Test-Path -LiteralPath (Join-Path $_ 'scripts\orchestrate-tasks.ps1'))}|Select-Object -First 1
    if(!$root){throw (New-SBError 'queue.script' @($PSScriptRoot))}
    $script=Join-Path $root 'scripts\orchestrate-tasks.ps1'
    $from=if($Checkout){$Checkout}else{(Get-Location).Path}
    $top=(& git -C $from rev-parse --show-toplevel 2>$null)
    if(!$top){throw (New-SBError 'queue.checkout')}
    $arguments=@('-NoProfile','-File',$script,'-Checkout',$top,'-SecondBrain',$root)
    if($Status){$arguments+='-Status'}elseif($Stop){$arguments+='-Stop'}elseif($Candidates){
        $arguments+='-Candidates'
        if($Limit){$arguments+=@('-Limit',[string]$Limit)}
        if($IncludeAdvisory){$arguments+='-IncludeAdvisory'}
        if($NeedsOwner){$arguments+='-NeedsOwner'}
        if($OnlyIds.Count){$arguments+=@('-OnlyIds',($OnlyIds -join ','))}
        if($ExcludeIds.Count){$arguments+=@('-ExcludeIds',($ExcludeIds -join ','))}
        if($TrackerPath){$arguments+=@('-TrackerPath',$TrackerPath)}
    }else{
        $arguments+=@('-Provider',$Provider)
        if($Model){$arguments+=@('-Model',$Model)}
        if($Effort){$arguments+=@('-Effort',$Effort)}
        if($MaxTasks){$arguments+=@('-MaxTasks',[string]$MaxTasks)}
        if($OnlyIds.Count){$arguments+=@('-OnlyIds',($OnlyIds -join ','))}
        if($ExcludeIds.Count){$arguments+=@('-ExcludeIds',($ExcludeIds -join ','))}
        if($Branch){$arguments+=@('-Branch',$Branch)}
        if($TrackerPath){$arguments+=@('-TrackerPath',$TrackerPath)}
        if($AllowNoPowerRequest){$arguments+='-AllowNoPowerRequest'}
    }
    if($Start){
        $process=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ($arguments+'-Run') -WorkingDirectory $top -PassThru
        [Console]::Error.WriteLine((Get-SBMessage 'queue.started' @($process.Id,$top)))
        exit 0
    }
    & (Get-Process -Id $PID).Path @arguments
    exit $LASTEXITCODE
}catch{
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
