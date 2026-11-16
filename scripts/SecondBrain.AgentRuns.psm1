#requires -Version 7.5
# Running agents (#627, plan item F09): start, stop, inspect and resume one agent run.
# Execution state is private: <run root>/<run id>/agent-run.json (run root under .runtime or a work folder), the same place and style as workflow-run.json.
# A run is bound to a subagent definition (ID and revision only, never a copy) and may wait on a user decision of decisions.json.
# Nothing here installs a service or resumes by itself: every transition is an explicit call, and Stop only ends the process whose ID and start time the record holds.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Decisions.psm1')
Add-SBMessages @{
    'agentrun.invalid' = @{ en = 'Invalid agent run ({0})' }
    'agentrun.notfound' = @{ en = 'No agent run with ID {0} in {1}' }
    'agentrun.state' = @{ en = 'Agent run {0} is {1}: {2}' }
    'agentrun.decision' = @{ en = 'Agent run {0} waits for decision {1}, which is {2}: only the user answers it (decisions.ps1 -Answer)' }
}
$script:SBAgentRunStates=@('running','waiting-user','stopped','finished','failed')
$script:SBAgentRunFileName='agent-run.json'

function Get-SBAgentRunPath([string]$RunRoot,[string]$RunId) {
    if($RunId -cnotmatch '^run-[0-9a-f]{8}$'){throw (New-SBError 'agentrun.invalid' @('runId'))}
    Join-Path (Join-Path $RunRoot $RunId) $script:SBAgentRunFileName
}
function Get-SBAgentRunTime { (Get-SBNow).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Get-SBAgentProcessStamp($ProcessId) {
    # The process start time identifies a process beyond its reusable ID; $null when it no longer runs.
    if($null -eq $ProcessId){return $null}
    $p=Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    if(!$p){return $null}
    try{$p.StartTime.ToUniversalTime().ToString('o')}catch{$null}
}

function Read-SBAgentRun([string]$RunRoot,[string]$RunId) {
    $path=Get-SBAgentRunPath $RunRoot $RunId
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'agentrun.notfound' @($RunId,$RunRoot))}
    $run=Read-SBJson $path $null
    if($run -isnot [System.Collections.IDictionary] -or $run.schemaVersion -ne 1 -or $run.runId -cne $RunId -or $run.state -cnotin $script:SBAgentRunStates -or $run.attempts -isnot [array]){throw (New-SBError 'agentrun.invalid' @('record'))}
    @{run=$run;path=$path;hash=(Get-SBFileHash $path)}
}

function Save-SBAgentRun($Run,[string]$Path,[string]$ExpectedHash) {
    Assert-SBPlainPath $Path
    $dir=Split-Path $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $Run.updatedAt=Get-SBAgentRunTime
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $Run))
    [void](Write-SBFile $Path $bytes $ExpectedHash (Join-Path $dir 'backups'))
}

function Get-SBAgentRunView($Run,[string]$State) {
    $last=if(@($Run.attempts).Count){@($Run.attempts)[-1]}else{$null}
    $alive=$false
    if($last -and $last.processId -and $last.processStart){$alive=((Get-SBAgentProcessStamp $last.processId) -ceq $last.processStart)}
    @{runId=$Run.runId;agent=$Run.agent;repository=$Run.repository;taskId=$Run.taskId;state=$Run.state;decisionId=$Run.decisionId;
      attempts=@($Run.attempts).Count;lastAttempt=$last;processAlive=$alive;createdAt=$Run.createdAt;updatedAt=$Run.updatedAt;result=$State}
}

function Start-SBAgentRun {
    # Records a new run (state running, attempt 1). -ProcessId is the process the caller launched for it, if any.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)]$Definition,[string]$TaskId='',[string]$ParentSession='',$ProcessId=$null)
    if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'agentrun.invalid' @('repository'))}
    if($Definition.schemaVersion -ne 2 -or $Definition.status -cne 'active'){throw (New-SBError 'agentrun.invalid' @('definition: an active schema 2 definition is required'))}
    $id=''
    do{$id='run-'+(New-SBId).Substring(0,8)}while(Test-Path -LiteralPath (Join-Path $RunRoot $id))
    $now=Get-SBAgentRunTime
    $run=[ordered]@{schemaVersion=1;runId=$id;repository=$Repository;taskId=$TaskId;parentSession=$ParentSession;
        agent=[ordered]@{id=$Definition.id;name=$Definition.name;revision=$Definition.revision};
        state='running';decisionId='';createdAt=$now;updatedAt=$now;
        attempts=@([ordered]@{number=1;startedAt=$now;endedAt='';processId=$ProcessId;processStart=(Get-SBAgentProcessStamp $ProcessId);outcome=''})}
    $path=Get-SBAgentRunPath $RunRoot $id
    Save-SBAgentRun $run $path 'absent'
    Get-SBAgentRunView $run 'started'
}

function Close-SBAgentAttempt($Run,[string]$Outcome) {
    $attempts=@($Run.attempts);$last=$attempts[-1]
    if(!$last.endedAt){$last.endedAt=Get-SBAgentRunTime;$last.outcome=$Outcome}
}

function Stop-SBAgentRun {
    # Ends the recorded process (only if its start time still matches) and marks the run stopped, or finished/failed with -Outcome.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[ValidateSet('stopped','finished','failed')][string]$Outcome='stopped')
    $r=Read-SBAgentRun $RunRoot $RunId;$run=$r.run
    if($run.state -cnotin @('running','waiting-user')){throw (New-SBError 'agentrun.state' @($RunId,$run.state,'only a running or waiting run can be stopped'))}
    $last=@($run.attempts)[-1];$killed=$false
    if($last.processId -and $last.processStart -and (Get-SBAgentProcessStamp $last.processId) -ceq $last.processStart){
        Stop-Process -Id ([int]$last.processId) -Force -ErrorAction SilentlyContinue;$killed=$true
        Wait-Process -Id ([int]$last.processId) -Timeout 10 -ErrorAction SilentlyContinue
    }
    Close-SBAgentAttempt $run $Outcome
    $run.state=$Outcome
    Save-SBAgentRun $run $r.path $r.hash
    $view=Get-SBAgentRunView $run $(if($killed){'process-stopped'}else{'recorded'})
    $view
}

function Suspend-SBAgentRun {
    # The agent asked the user something: the run waits on the decision ID and stays stopped until it is answered.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$DecisionId)
    if($DecisionId -cnotmatch '^dec-[0-9a-f]{8}$'){throw (New-SBError 'agentrun.invalid' @('decisionId'))}
    $r=Read-SBAgentRun $RunRoot $RunId;$run=$r.run
    if($run.state -cne 'running'){throw (New-SBError 'agentrun.state' @($RunId,$run.state,'only a running run can wait for a decision'))}
    Close-SBAgentAttempt $run 'waiting-user'
    $run.state='waiting-user';$run.decisionId=$DecisionId
    Save-SBAgentRun $run $r.path $r.hash
    Get-SBAgentRunView $run 'waiting'
}

function Resume-SBAgentRun {
    # An explicit new attempt of a stopped or waiting run. A waiting run needs its decision answered by the user (read from decisions.json).
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[string]$Dossier,$ProcessId=$null)
    $r=Read-SBAgentRun $RunRoot $RunId;$run=$r.run
    if($run.state -cnotin @('stopped','waiting-user')){throw (New-SBError 'agentrun.state' @($RunId,$run.state,'only a stopped or waiting run can resume'))}
    if($run.state -ceq 'waiting-user'){
        if(!$Dossier){throw (New-SBError 'agentrun.invalid' @('dossier'))}
        $decision=Find-SBDecision (Read-SBDecisions $Dossier $run.repository).data $run.decisionId
        if($decision.status -cne 'answered' -or $decision.answer.by -cne 'user'){throw (New-SBError 'agentrun.decision' @($RunId,$run.decisionId,$decision.status))}
    }
    $now=Get-SBAgentRunTime
    $run.attempts=@($run.attempts)+@([ordered]@{number=@($run.attempts).Count+1;startedAt=$now;endedAt='';processId=$ProcessId;processStart=(Get-SBAgentProcessStamp $ProcessId);outcome=''})
    $run.state='running'
    Save-SBAgentRun $run $r.path $r.hash
    Get-SBAgentRunView $run 'resumed'
}

function Get-SBAgentRunInspection {
    param([Parameter(Mandatory)][string]$RunRoot,[string]$RunId)
    if($RunId){return (Get-SBAgentRunView (Read-SBAgentRun $RunRoot $RunId).run 'inspected')}
    $views=@()
    if(Test-Path -LiteralPath $RunRoot -PathType Container){
        foreach($d in (Get-ChildItem -LiteralPath $RunRoot -Directory|Where-Object {$_.Name -cmatch '^run-[0-9a-f]{8}$'}|Sort-Object Name)){
            $views+=,(Get-SBAgentRunView (Read-SBAgentRun $RunRoot $d.Name).run 'inspected')
        }
    }
    @{runs=$views;count=$views.Count}
}

Export-ModuleMember -Function @('Start-SBAgentRun','Stop-SBAgentRun','Suspend-SBAgentRun','Resume-SBAgentRun','Get-SBAgentRunInspection','Read-SBAgentRun')
