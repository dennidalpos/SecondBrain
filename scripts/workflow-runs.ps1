#requires -Version 7.5
<#
.SYNOPSIS
Workflow runs (#576): start, advance, answer a gate, record a step, stop, resume and inspect one run of a shipped workflow.
.DESCRIPTION
A run is a private record <run root>/<run id>/workflow-run.json (run root under .runtime) pinned to the workflow ID and revision and to the hash of every card it uses.
The run tracks state and launches nothing: the person executes each step's prompt and records the outcome.
-Operation List: the active workflows this workstation can run (enabled packs only), with their steps. -Operation Start -Key <wf-key|wfl-id> [-Objective text] [-Skip step,step]: records the run, every step pending.
-Operation Step -RunId [-Option pmt-id]: starts the first step that is not done; a confirm gate opens a decision and the run waits; a choice step needs -Option.
-Operation Answer -RunId -Step <slug> -Answer yes|no: the person answers a confirm gate (yes starts the step, no stops the run or skips an optional step).
-Operation Complete -RunId -Step <slug> [-Outcome done|failed] [-Evidence text]: the person records the outcome of the running step.
-Operation Stop -RunId: the running step goes back to pending. -Operation Resume -RunId: continues from the first step that is not done.
-Operation Inspect [-RunId]: read-only state of one run or of all runs. -Operation Pins -RunId: reports the cards that changed since the run was pinned.
Start, Step, Answer, Complete, Stop and Resume preview unless -Apply. Nothing resumes by itself: every transition is an explicit call.
.EXAMPLE
pwsh -NoProfile -File scripts/workflow-runs.ps1 -Operation Inspect -Repository github.com/my-org/my-product -RunRoot .runtime/workflow-runs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('List','Start','Step','Answer','Complete','Stop','Resume','Inspect','Pins')][string]$Operation,
    [Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$RunRoot,
    [string]$Key,[string]$Objective='',[string[]]$Skip=@(),[string]$RunId,[string]$Option='',[string]$Step,
    [ValidateSet('yes','no')][string]$Answer,[ValidateSet('done','failed')][string]$Outcome='done',[string]$Evidence='',[switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($m in 'Core','Access','Host','Entity','Prompts','WorkflowRuns'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
$brain=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'workflowrun.invalid' @('repository'))}
$scope=[IO.Path]::GetFullPath((Join-Path $brain '.runtime')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$root=[IO.Path]::GetFullPath($RunRoot,$brain)
if(!$root.StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'workflowrun.invalid' @('runRoot'))}
if($Operation -eq 'List'){
    $catalog=Read-SBWorkflowCatalog $brain
    $enabled=@(Get-SBEnabledPromptPacks $brain)
    $byId=@{};foreach($p in $catalog.prompts){$byId[$p.id]=$p}
    $flows=@(Read-SBPromptWorkflows $brain $catalog|Where-Object {$_.status -ceq 'active' -and (!$_.ContainsKey('pack') -or $_.pack -ceq 'core' -or $_.pack -cin $enabled)}|ForEach-Object {
        $f=$_
        [ordered]@{id=$f.id;key=$f.key;title=$f.title;revision=$f.revision;pack=$(if($f.ContainsKey('pack')){$f.pack}else{'core'})
            steps=@($f.steps|ForEach-Object {[ordered]@{step=$_.step;ref=$_.ref;code=$byId[$_.ref].code;summary=$byId[$_.ref].summary;kind=$_.kind;gate=$_.gate;choices=@(if($_.ContainsKey('choices')){$_.choices|ForEach-Object {[ordered]@{ref=$_;code=$byId[$_].code;summary=$byId[$_].summary}}})}})}
    })
    ConvertTo-SBJson @{workflows=$flows;count=$flows.Count};exit 0
}
if($Operation -eq 'Inspect'){ConvertTo-SBJson (Get-SBWorkflowRunInspection $root $RunId);exit 0}
if($Operation -eq 'Pins'){if(!$RunId){throw (New-SBError 'workflowrun.invalid' @('runId'))};ConvertTo-SBJson (Test-SBWorkflowRunPins $brain $root $RunId);exit 0}
if($Operation -ne 'Start' -and !$RunId){throw (New-SBError 'workflowrun.invalid' @('runId'))}
if($Operation -in @('Answer','Complete') -and !$Step){throw (New-SBError 'workflowrun.invalid' @('step'))}
if($Operation -eq 'Answer' -and !$Answer){throw (New-SBError 'workflowrun.invalid' @('answer'))}
if(!$Apply){ConvertTo-SBJson @{state='preview';operation=$Operation;runId=$RunId;key=$Key;note='Nothing changed; repeat with -Apply.'};exit 0}
$result=switch($Operation){
    'Start' {
        if(!$Key){throw (New-SBError 'workflowrun.invalid' @('key'))}
        $catalog=Read-SBWorkflowCatalog $brain
        $flow=@(Read-SBPromptWorkflows $brain $catalog|Where-Object {$_.key -ceq $Key -or $_.id -ceq $Key})
        if($flow.Count -ne 1){throw (New-SBError 'workflowrun.invalid' @('key'))}
        Assert-SBPromptPackEnabled $brain ([pscustomobject]@{pack=$(if($flow[0].ContainsKey('pack')){$flow[0].pack}else{'core'});code=$flow[0].key})
        Start-SBWorkflowRun -BrainRoot $brain -RunRoot $root -Repository $Repository -Workflow $flow[0] -Catalog $catalog -Objective $Objective -Skip $Skip
    }
    'Step' {Step-SBWorkflowRun -RunRoot $root -RunId $RunId -Option $Option}
    'Answer' {Set-SBWorkflowGateAnswer -RunRoot $root -RunId $RunId -Step $Step -Answer $Answer}
    'Complete' {Complete-SBWorkflowStep -RunRoot $root -RunId $RunId -Step $Step -Outcome $Outcome -Evidence $Evidence}
    'Stop' {Stop-SBWorkflowRun -RunRoot $root -RunId $RunId}
    'Resume' {Resume-SBWorkflowRun -RunRoot $root -RunId $RunId}
}
ConvertTo-SBJson $result
