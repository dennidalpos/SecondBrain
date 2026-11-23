#requires -Version 7.5
# Workflow runs (#576, plan item E02): a run is pinned to the workflow revision and to the hash of every card it uses, persists the status of each step,
# its gate decision and its evidence pointer, and resumes from the first step that is not done without repeating verified steps.
# Execution state is private: <run root>/<run id>/workflow-run.json (run root under .runtime). The workflow definition is never copied, only its ID and revision.
# The run tracks state; it launches nothing. A human step waits until the person records completion, and a confirm gate waits until the person answers.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Add-SBMessages @{
    'workflowrun.invalid' = @{ en = 'Invalid workflow run ({0})' }
    'workflowrun.notfound' = @{ en = 'No workflow run with ID {0} in {1}' }
    'workflowrun.state' = @{ en = 'Workflow run {0} is {1}: {2}' }
    'workflowrun.step' = @{ en = 'Workflow run {0}, step {1}: {2}' }
}
$script:SBWorkflowRunStates=@('running','waiting-user','stopped','finished','failed')
$script:SBWorkflowStepStates=@('pending','running','waiting-user','done','skipped','failed')
$script:SBWorkflowRunFileName='workflow-run.json'

function Get-SBWorkflowRunPath([string]$RunRoot,[string]$RunId) {
    if($RunId -cnotmatch '^run-[0-9a-f]{8}$'){throw (New-SBError 'workflowrun.invalid' @('runId'))}
    Join-Path (Join-Path $RunRoot $RunId) $script:SBWorkflowRunFileName
}
function Get-SBWorkflowRunTime { (Get-SBNow).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Read-SBWorkflowRun([string]$RunRoot,[string]$RunId) {
    $path=Get-SBWorkflowRunPath $RunRoot $RunId
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'workflowrun.notfound' @($RunId,$RunRoot))}
    $run=Read-SBJson $path $null
    if($run -isnot [System.Collections.IDictionary] -or $run.schemaVersion -ne 1 -or $run.runId -cne $RunId -or $run.state -cnotin $script:SBWorkflowRunStates -or $run.steps -isnot [array] -or !$run.steps.Count){throw (New-SBError 'workflowrun.invalid' @('record'))}
    foreach($s in $run.steps){if($s -isnot [System.Collections.IDictionary] -or $s.status -cnotin $script:SBWorkflowStepStates){throw (New-SBError 'workflowrun.invalid' @('step'))}}
    @{run=$run;path=$path;hash=(Get-SBFileHash $path)}
}

function Save-SBWorkflowRun($Run,[string]$Path,[string]$ExpectedHash) {
    Assert-SBPlainPath $Path
    $dir=Split-Path $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $Run.updatedAt=Get-SBWorkflowRunTime
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $Run))
    [void](Write-SBFile $Path $bytes $ExpectedHash (Join-Path $dir 'backups'))
}

function Get-SBWorkflowRunView($Run,[string]$Result) {
    $steps=@($Run.steps|ForEach-Object {
        [ordered]@{step=$_.step;ref=$_.ref;kind=$_.kind;gate=$_.gate;status=$_.status;choice=$_.choice;decisionId=$_.decisionId;decision=$_.decision;evidence=$_.evidence;startedAt=$_.startedAt;endedAt=$_.endedAt}
    })
    $next=@($steps|Where-Object {$_.status -cnotin @('done','skipped')})
    @{runId=$Run.runId;repository=$Run.repository;workflow=$Run.workflow;objective=$Run.objective;state=$Run.state;steps=$steps;
      current=$(if($next.Count){$next[0].step}else{$null});done=@($steps|Where-Object {$_.status -ceq 'done'}).Count;total=$steps.Count;
      createdAt=$Run.createdAt;updatedAt=$Run.updatedAt;result=$Result}
}

function Start-SBWorkflowRun {
    # Records a new run: every step pending (optional steps named in -Skip start skipped), the workflow revision and the card hashes pinned.
    param([Parameter(Mandatory)][string]$BrainRoot,[Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)]$Workflow,[Parameter(Mandatory)]$Catalog,[string]$Objective='',[string[]]$Skip=@())
    if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'workflowrun.invalid' @('repository'))}
    if($Workflow.status -cne 'active'){throw (New-SBError 'workflowrun.invalid' @('workflow: only an active workflow can run'))}
    if($Objective.Length -gt 2000 -or $Objective -match '[\x00-\x08\x0B\x0C\x0E-\x1F]'){throw (New-SBError 'workflowrun.invalid' @('objective'))}
    $byId=@{};foreach($p in $Catalog.prompts){$byId[$p.id]=$p}
    $known=@($Workflow.steps|ForEach-Object {$_.step})
    foreach($name in $Skip){
        $match=@($Workflow.steps|Where-Object {$_.step -ceq $name})
        if(!$match.Count){throw (New-SBError 'workflowrun.invalid' @('skip: unknown step '+$name))}
        if($match[0].kind -ceq 'required'){throw (New-SBError 'workflowrun.invalid' @('skip: a required step cannot be skipped ('+$name+')'))}
    }
    $now=Get-SBWorkflowRunTime
    $cards=[ordered]@{}
    $steps=@(foreach($s in $Workflow.steps){
        $card=$byId[$s.ref]
        if(!$card){throw (New-SBError 'workflowrun.invalid' @('step ref '+$s.ref))}
        foreach($ref in @($s.ref)+@(if($s.Contains('choices')){$s.choices})){
            if(!$cards.Contains($ref)){$c=$byId[$ref];$cards[$ref]=(Get-SBFileHash (Resolve-SBParaPath $BrainRoot ('directives/prompts/'+$c.file)))}
        }
        $skipped=$s.step -cin $Skip
        [ordered]@{step=$s.step;ref=$s.ref;kind=$s.kind;gate=$s.gate;
            choices=@(if($s.Contains('choices')){$s.choices});choice='';status=$(if($skipped){'skipped'}else{'pending'});
            decisionId='';decision=$null;evidence='';startedAt='';endedAt=$(if($skipped){$now}else{''})}
    })
    $id=''
    do{$id='run-'+(New-SBId).Substring(0,8)}while(Test-Path -LiteralPath (Join-Path $RunRoot $id))
    $run=[ordered]@{schemaVersion=1;runId=$id;repository=$Repository;objective=$Objective;
        workflow=[ordered]@{id=$Workflow.id;key=$Workflow.key;revision=$Workflow.revision;title=$Workflow.title};pinned=$cards;
        state='running';createdAt=$now;updatedAt=$now;steps=$steps}
    if(@($steps|Where-Object {$_.status -cne 'skipped'}).Count -eq 0){$run.state='finished'}
    Save-SBWorkflowRun $run (Get-SBWorkflowRunPath $RunRoot $id) 'absent'
    Get-SBWorkflowRunView $run 'started'
}

function Find-SBWorkflowStep($Run,[string]$Step,[string[]]$Statuses) {
    $match=@($Run.steps|Where-Object {$_.step -ceq $Step})
    if($match.Count -ne 1){throw (New-SBError 'workflowrun.step' @($Run.runId,$Step,'unknown step'))}
    if($Statuses -and $match[0].status -cnotin $Statuses){throw (New-SBError 'workflowrun.step' @($Run.runId,$Step,('is '+$match[0].status+'; expected '+($Statuses -join ' or '))))}
    $match[0]
}

function Step-SBWorkflowRun {
    # Starts the first step that is not done: an auto step runs at once, a confirm gate opens a decision and the run waits for the person.
    # A choice step needs -Option (one of its card refs). A step already waiting stays waiting until it is answered.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[string]$Option='')
    $r=Read-SBWorkflowRun $RunRoot $RunId;$run=$r.run
    if($run.state -cnotin @('running','waiting-user')){throw (New-SBError 'workflowrun.state' @($RunId,$run.state,'only a running or waiting run advances; resume a stopped or failed run first'))}
    $open=@($run.steps|Where-Object {$_.status -cnotin @('done','skipped')})
    if(!$open.Count){$run.state='finished';Save-SBWorkflowRun $run $r.path $r.hash;return (Get-SBWorkflowRunView $run 'finished')}
    $step=$open[0];$now=Get-SBWorkflowRunTime
    if($step.status -ceq 'running'){return (Get-SBWorkflowRunView $run 'running')}
    if($step.status -ceq 'waiting-user'){return (Get-SBWorkflowRunView $run 'waiting')}
    if($step.kind -ceq 'choice' -and !$step.choice){
        if($Option -cnotin @($step.choices)){throw (New-SBError 'workflowrun.step' @($RunId,$step.step,('choose one of: '+(@($step.choices) -join ', '))))}
        $step.choice=$Option
    }
    $approved=$step.decision -is [System.Collections.IDictionary] -and $step.decision.status -ceq 'answered' -and $step.decision.answer -ceq 'yes'
    if($step.gate -ceq 'confirm' -and !$approved){
        $step.status='waiting-user';$step.startedAt=$now
        $step.decisionId='dec-'+(New-SBId).Substring(0,8)
        $step.decision=[ordered]@{status='open';kind='confirm';question=('Run step '+$step.step+'?');options=@('yes','no');answer='';answeredAt='';by=''}
        $run.state='waiting-user'
        Save-SBWorkflowRun $run $r.path $r.hash
        return (Get-SBWorkflowRunView $run 'waiting')
    }
    $step.status='running';$step.startedAt=$now;$step.endedAt=''
    $run.state='running'
    Save-SBWorkflowRun $run $r.path $r.hash
    Get-SBWorkflowRunView $run 'step-started'
}

function Set-SBWorkflowGateAnswer {
    # Only the person answers a confirm gate: yes lets the step start, no stops the run (an optional step is skipped instead).
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Step,[Parameter(Mandatory)][ValidateSet('yes','no')][string]$Answer)
    $r=Read-SBWorkflowRun $RunRoot $RunId;$run=$r.run
    $s=Find-SBWorkflowStep $run $Step @('waiting-user')
    if($s.decision -isnot [System.Collections.IDictionary] -or $s.decision.status -cne 'open'){throw (New-SBError 'workflowrun.step' @($RunId,$Step,'has no open decision'))}
    $now=Get-SBWorkflowRunTime
    $s.decision.status='answered';$s.decision.answer=$Answer;$s.decision.answeredAt=$now;$s.decision.by='user'
    if($Answer -ceq 'yes'){$s.status='pending';$run.state='running'}
    elseif($s.kind -ceq 'optional'){$s.status='skipped';$s.endedAt=$now;$run.state='running'}
    else{$s.status='pending';$run.state='stopped'}
    Save-SBWorkflowRun $run $r.path $r.hash
    Get-SBWorkflowRunView $run 'answered'
}

function Complete-SBWorkflowStep {
    # The person records the outcome of the running step with an evidence pointer; the last verified step finishes the run, a failure fails it.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Step,[ValidateSet('done','failed')][string]$Outcome='done',[string]$Evidence='')
    if($Evidence.Length -gt 1000 -or $Evidence -match '[\x00-\x08\x0B\x0C\x0E-\x1F]'){throw (New-SBError 'workflowrun.invalid' @('evidence'))}
    $r=Read-SBWorkflowRun $RunRoot $RunId;$run=$r.run
    if($run.state -cne 'running'){throw (New-SBError 'workflowrun.state' @($RunId,$run.state,'only a running run records a step'))}
    $s=Find-SBWorkflowStep $run $Step @('running')
    $s.status=$Outcome;$s.endedAt=Get-SBWorkflowRunTime;$s.evidence=$Evidence
    if($Outcome -ceq 'failed'){$run.state='failed'}
    elseif(!@($run.steps|Where-Object {$_.status -cnotin @('done','skipped')}).Count){$run.state='finished'}
    Save-SBWorkflowRun $run $r.path $r.hash
    Get-SBWorkflowRunView $run 'recorded'
}

function Stop-SBWorkflowRun {
    # Marks the run stopped; the running step goes back to pending, so a resume repeats only work that was never recorded as done.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId)
    $r=Read-SBWorkflowRun $RunRoot $RunId;$run=$r.run
    if($run.state -cnotin @('running','waiting-user')){throw (New-SBError 'workflowrun.state' @($RunId,$run.state,'only a running or waiting run can be stopped'))}
    foreach($s in $run.steps){if($s.status -ceq 'running'){$s.status='pending';$s.startedAt=''}}
    $run.state='stopped'
    Save-SBWorkflowRun $run $r.path $r.hash
    Get-SBWorkflowRunView $run 'stopped'
}

function Resume-SBWorkflowRun {
    # A stopped or failed run continues from the first step that is not done; done and skipped steps are never repeated. A failed step is retried.
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$RunId)
    $r=Read-SBWorkflowRun $RunRoot $RunId;$run=$r.run
    if($run.state -cnotin @('stopped','failed')){throw (New-SBError 'workflowrun.state' @($RunId,$run.state,'only a stopped or failed run can resume'))}
    foreach($s in $run.steps){if($s.status -ceq 'failed'){$s.status='pending';$s.endedAt='';$s.evidence=''}}
    $waiting=@($run.steps|Where-Object {$_.status -ceq 'waiting-user'})
    $run.state=if($waiting.Count){'waiting-user'}else{'running'}
    Save-SBWorkflowRun $run $r.path $r.hash
    Get-SBWorkflowRunView $run 'resumed'
}

function Get-SBWorkflowRunInspection {
    param([Parameter(Mandatory)][string]$RunRoot,[string]$RunId)
    if($RunId){return (Get-SBWorkflowRunView (Read-SBWorkflowRun $RunRoot $RunId).run 'inspected')}
    $views=@()
    if(Test-Path -LiteralPath $RunRoot -PathType Container){
        foreach($d in (Get-ChildItem -LiteralPath $RunRoot -Directory|Where-Object {$_.Name -cmatch '^run-[0-9a-f]{8}$'}|Sort-Object Name)){
            if(Test-Path -LiteralPath (Join-Path $d.FullName $script:SBWorkflowRunFileName) -PathType Leaf){$views+=,(Get-SBWorkflowRunView (Read-SBWorkflowRun $RunRoot $d.Name).run 'inspected')}
        }
    }
    @{runs=$views;count=$views.Count}
}

function Test-SBWorkflowRunPins([string]$BrainRoot,[string]$RunRoot,[string]$RunId) {
    # The cards a run was pinned to: a changed card file is reported, never silently followed.
    $run=(Read-SBWorkflowRun $RunRoot $RunId).run
    $catalog=Read-SBWorkflowCatalog $BrainRoot
    $byId=@{};foreach($p in $catalog.prompts){$byId[$p.id]=$p}
    $changed=@(foreach($ref in $run.pinned.Keys){
        $p=$byId[$ref]
        $now=if($p){Get-SBFileHash (Resolve-SBParaPath $BrainRoot ('directives/prompts/'+$p.file))}else{''}
        if($now -cne $run.pinned[$ref]){if($p){$p.code}else{$ref}}
    })
    @{runId=$RunId;changed=$changed;pinned=$run.pinned.Count}
}

Export-ModuleMember -Function @('Start-SBWorkflowRun','Step-SBWorkflowRun','Set-SBWorkflowGateAnswer','Complete-SBWorkflowStep','Stop-SBWorkflowRun','Resume-SBWorkflowRun','Get-SBWorkflowRunInspection','Read-SBWorkflowRun','Test-SBWorkflowRunPins')
