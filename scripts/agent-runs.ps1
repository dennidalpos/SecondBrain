#requires -Version 7.5
<#
.SYNOPSIS
Running agents (#627): start, stop, inspect and resume one agent run, with decision handling.
.DESCRIPTION
A run is a private record <run root>/<run id>/agent-run.json (run root under .runtime) bound to an active schema 2 subagent definition by ID and revision.
-Operation Start -Name <definition>: records the run (attempt 1); -ProcessId is the process you launched for it, if any.
-Operation Stop -RunId: ends the recorded process only if its start time still matches, then marks the run stopped (or -Outcome finished|failed).
-Operation Wait -RunId -DecisionId: the agent asked the user; the run waits on that decision (decisions.ps1 -Open).
-Operation Resume -RunId: a new attempt of a stopped or waiting run; a waiting run needs its decision answered by the user.
-Operation Inspect [-RunId]: read-only state of one run or of all runs.
Start, Stop, Wait and Resume preview unless -Apply. Nothing is installed and nothing resumes by itself: every transition is an explicit call.
.EXAMPLE
pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Inspect -Repository github.com/my-org/my-product -RunRoot .runtime/agent-runs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Start','Stop','Wait','Resume','Inspect')][string]$Operation,
    [Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$RunRoot,
    [string]$Name,[string]$TaskId,[string]$ParentSession,[string]$RunId,[string]$DecisionId,[Nullable[int]]$ProcessId,
    [ValidateSet('stopped','finished','failed')][string]$Outcome='stopped',[switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($m in 'Core','Access','Host','Para','Knowledge','Subagents','AgentRuns'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
$brain=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'agentrun.invalid' @('repository'))}
$scope=[IO.Path]::GetFullPath((Join-Path $brain '.runtime')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$root=[IO.Path]::GetFullPath($RunRoot,$brain)
if(!$root.StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'agentrun.invalid' @('runRoot'))}
$dossier=Resolve-SBParaPath $brain (Resolve-SBWorkingDossier $brain $Repository)
if($Operation -eq 'Inspect'){ConvertTo-SBJson (Get-SBAgentRunInspection $root $RunId);exit 0}
if($Operation -ne 'Start' -and !$RunId){throw (New-SBError 'agentrun.invalid' @('runId'))}
if(!$Apply){ConvertTo-SBJson @{state='preview';operation=$Operation;runId=$RunId;name=$Name;note='Nothing changed; repeat with -Apply.'};exit 0}
$result=switch($Operation){
    'Start' {
        if(!$Name){throw (New-SBError 'agentrun.invalid' @('name'))}
        $entry=@(Read-SBSubagentDefinitions $dossier (Read-SBSubagentCatalog $brain)|Where-Object {$_.definition.name -ceq $Name})
        if($entry.Count -ne 1){throw (New-SBError 'agentrun.invalid' @('name'))}
        Start-SBAgentRun -RunRoot $root -Repository $Repository -Definition $entry[0].definition -TaskId $TaskId -ParentSession $ParentSession -ProcessId $ProcessId
    }
    'Stop' {Stop-SBAgentRun -RunRoot $root -RunId $RunId -Outcome $Outcome}
    'Wait' {Suspend-SBAgentRun -RunRoot $root -RunId $RunId -DecisionId $DecisionId}
    'Resume' {Resume-SBAgentRun -RunRoot $root -RunId $RunId -Dossier $dossier -ProcessId $ProcessId}
}
ConvertTo-SBJson $result
