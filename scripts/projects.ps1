#requires -Version 7.5
<#
.SYNOPSIS
Read-only list of the projects bound on this workstation, with the task counts of each tracker.
.DESCRIPTION
Prints JSON {projects:[...]}: identity, name, checkout path, dossier, whether the checkout exists, task counts by status, tracker update time
and the effective gitUpdate preference. Nothing is written, locked or processed. Exit: 0 ok, 2 error.
.EXAMPLE
pwsh -NoProfile -File scripts/projects.ps1 -List
#>
[CmdletBinding()]
param([Parameter(Mandatory)][switch]$List,[string]$ConfigPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1') -Force
try{
    $config=Read-SBConfiguration $ConfigPath -ReadOnly
    $statuses=@('todo','in_progress','blocked','done','cancelled')
    $projects=@(foreach($binding in @($config.bindings|Sort-Object {[string]$_.identity})){
        $dossier=if($binding.ContainsKey('dossier')){[string]$binding.dossier}else{''}
        $record=$null;$counts=[ordered]@{total=0};foreach($s in $statuses){$counts[$s]=0};$updated=$null
        if($dossier){
            $dir=Resolve-SBParaPath $config.brainRoot $dossier
            $recordPath=Join-Path $dir 'repository.json'
            if(Test-Path -LiteralPath $recordPath -PathType Leaf){$record=Read-SBJson $recordPath $null}
            $trackerFile=if($record -and $record.ContainsKey('tracker') -and $record.tracker.location -eq 'dossier' -and $record.tracker.path){Join-Path $dir ([string]$record.tracker.path)}else{''}
            if($trackerFile -and (Test-Path -LiteralPath $trackerFile -PathType Leaf)){
                $tracker=Read-SBJson $trackerFile $null
                if($tracker.ContainsKey('updatedAt')){$updated=[string]$tracker.updatedAt}
                foreach($task in @($tracker.tasks)){
                    $counts.total++
                    $status=[string]$task.status
                    if($counts.Contains($status)){$counts[$status]++}
                }
            }
        }
        [ordered]@{
            identity=[string]$binding.identity
            name=[IO.Path]::GetFileName(([string]$binding.path).TrimEnd('\','/'))
            path=[string]$binding.path
            dossier=$dossier
            checkoutExists=[bool](Test-Path -LiteralPath ([string]$binding.path) -PathType Container)
            tasks=$counts
            trackerUpdatedAt=$updated
            gitUpdate=(Get-SBGitUpdate $record)
        }
    })
    ConvertTo-SBJson @{projects=$projects}
    exit 0
}catch{
    Write-Error $_ -ErrorAction Continue
    exit 2
}
