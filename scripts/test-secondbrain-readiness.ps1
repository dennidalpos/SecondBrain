#requires -Version 7.5
# Task autonomy check (#723): files in scope and checks to run are advisory unless -Strict; the analysis lists what is missing per task.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1') -Force
$script:rdChecks=0
function Assert-Rd($Condition,[string]$Message){if(!$Condition){throw ('FAIL READINESS: '+$Message)};$script:rdChecks++}
$prov=@(@{reference='docs/plan.md';sha256=('A'*64)})
function New-Task($Extra=@{}){
    $ext=@{stream='runner'}+$Extra
    @{id='T-1';seq=1;title='#001 — A complete runnable task';description='Do the work';status='todo';priority='P2';execution='autonomous';dependencies=@();acceptance=@('It works');evidence=@();provenance=$prov;extensions=$ext}
}
$plain=Get-SBTaskReadiness (New-Task) @() $null
Assert-Rd ($plain.ready -and @($plain.advisory) -contains 'files' -and @($plain.advisory) -contains 'checks') 'a complete task stays ready and lists files and checks as advisory'
$full=Get-SBTaskReadiness (New-Task @{files=@('scripts/a.ps1');checks=@('scripts/test-secondbrain.ps1 -Quick')}) @() $null
Assert-Rd ($full.ready -and !@($full.advisory).Count) 'files and checks present: nothing advisory'
$strict=Get-SBTaskReadiness (New-Task) @() $null -Strict
Assert-Rd (!$strict.ready -and @($strict.missing) -contains 'verification' -and !@($strict.advisory).Count) '-Strict makes missing files and checks blocking'
$strictOk=Get-SBTaskReadiness (New-Task @{files=@('a');checks=@('b')}) @() $null -Strict
Assert-Rd ($strictOk.ready) '-Strict passes with both present'
$noAcceptance=New-Task;$noAcceptance.acceptance=@()
$gap=Get-SBTaskReadiness $noAcceptance @() $null
Assert-Rd (!$gap.ready -and @($gap.missing) -contains 'acceptance') 'a task without acceptance is still not ready'
$decision=Get-SBTaskReadiness (New-Task @{decision='dec-12345678'}) @() $null
Assert-Rd (!$decision.ready -and @($decision.missing) -contains 'decisions') 'an open user decision still blocks'
# Self-sufficiency for the unattended queue: an autonomous task lists what the agent must still ask the user for; a task the user marked otherwise is exempt.
function Add-Readiness($Task){$Task.extensions.readiness=(Get-SBTaskReadiness $Task @() $null);$Task}
$needsPlain=@(Get-SBTaskInfoNeeds (Add-Readiness (New-Task)))
Assert-Rd (($needsPlain -contains 'files') -and ($needsPlain -contains 'checks') -and $needsPlain.Count -eq 2) 'an autonomous task without files and checks must ask for both'
$needsFull=@(Get-SBTaskInfoNeeds (Add-Readiness (New-Task @{files=@('a');checks=@('b')})))
Assert-Rd ($needsFull.Count -eq 0) 'a self-sufficient task asks for nothing'
$gapTask=New-Task @{files=@('a');checks=@('b')};$gapTask.acceptance=@()
Assert-Rd (@(Get-SBTaskInfoNeeds (Add-Readiness $gapTask)) -contains 'acceptance:acceptance') 'a blocking gap is reported as check:code'
$userTask=New-Task;$userTask.execution='user_required'
Assert-Rd (@(Get-SBTaskInfoNeeds (Add-Readiness $userTask)).Count -eq 0) 'a task the user marked user_required is exempt'
$doneTask=New-Task;$doneTask.status='done'
Assert-Rd (@(Get-SBTaskInfoNeeds (Add-Readiness $doneTask)).Count -eq 0) 'a closed task asks for nothing'
# Creation with stream, files and checks (#770): the stored extensions make the new task self-sufficient.
$createRoot=Join-Path ([IO.Path]::GetTempPath()) ('sb-readiness-'+[Guid]::NewGuid().ToString('N'))
try{
    $createId='local:'+('a'*32)
    $createBrain=Join-Path $createRoot 'brain';$createDossier=Join-Path $createBrain 'repos/r1'
    New-Item -ItemType Directory -Force -Path (Join-Path $createDossier 'history') | Out-Null
    [IO.File]::WriteAllText((Join-Path $createDossier 'source.md'),'source')
    $createTracker=Join-Path $createDossier 'tracker.json'
    [IO.File]::WriteAllText($createTracker,('{"schemaVersion":1,"repository":"'+$createId+'","updatedAt":"2026-11-20T00:00:00Z","tasks":[],"history":[],"extensions":{"lastSeq":0}}'))
    $created=New-SBTrackerTaskEntry -BrainRoot $createBrain -Identity $createId -Path $createTracker -WorkingRepository $createId -Title 'Self sufficient creation' -Description 'Change the fixture only.' -Acceptance @('It works') -ProvenanceReference 'source.md' -Stream 'runner' -Files @('scripts/a.ps1') -Checks @('scripts/test-secondbrain.ps1 -Quick') -BackupRoot (Join-Path $createRoot 'backup')
    Assert-Rd (!@($created.needsInfo).Count) 'a task created with stream, files and checks returns an empty needsInfo'
    $stored=@((Get-Content -Raw $createTracker|ConvertFrom-Json -AsHashtable).tasks)[0]
    Assert-Rd ($stored.extensions.stream -ceq 'runner' -and @($stored.extensions.files) -contains 'scripts/a.ps1' -and @($stored.extensions.checks) -contains 'scripts/test-secondbrain.ps1 -Quick') 'creation stores extensions.stream, files and checks'
}finally{Remove-Item -LiteralPath $createRoot -Recurse -Force -ErrorAction SilentlyContinue}
'SUCCESS READINESS: '+$script:rdChecks+' checks'
