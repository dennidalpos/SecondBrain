#requires -Version 7.5
# #706: sb reconcile tasks on a synthetic brain: conflict classes, safe apply, user decisions, orphan receipts, CLI wiring. Real queues are never touched.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Knowledge.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Pending.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Reconcile.psm1') -Force
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
$null=Enter-SBTestGitEnvironment
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:checks=0
function Assert-Reconcile($Value,[string]$Message){if(!$Value){throw ('FAIL RECONCILE: '+$Message)};$script:checks++}
function Write-ReconcileFile([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$fixture=Join-Path (Get-SBTestRoot) ('reconcile-'+[guid]::NewGuid().ToString('N'))
$brain=Join-Path $fixture 'brain'
$dossier=Join-Path $brain 'repos/Reconcile'
$checkout=Join-Path $fixture 'checkout'
$identity='github.com/test/reconcile'
$hostId=Get-SBHostId
$runtime=Join-Path $brain ('.runtime/hosts/'+$hostId)
$configPath=Join-Path $runtime 'workstation.json'
$scope=Get-SBScopeKey $identity
$sessionId=$null;$lock=$null
function Invoke-ReconcileCli([string[]]$CliArguments){
    $lines=@(& pwsh -NoProfile -File (Join-Path $brain 'scripts/reconcile-tasks.ps1') -ConfigPath $configPath @CliArguments 2>&1)
    $text=($lines|ForEach-Object {[string]$_}) -join "`n"
    $data=$null;try{$data=$text|ConvertFrom-Json -AsHashtable}catch{Write-Verbose $_.Exception.Message}
    @{code=$LASTEXITCODE;text=$text;data=$data}
}
function Invoke-ReconcileLocked([hashtable]$Parameters){
    $held=Enter-SBOperation $cfg -WaitMs 5000 -Scope $scope
    try{Invoke-SBReconcile -BrainRoot $brain -Config $cfg @Parameters}finally{Exit-SBOperation $held}
}
function Get-ReconcileTask([string]$Id){
    $current=Read-SBJson $trackerPath $null
    $archived=(Read-SBTrackerArchive $trackerPath $identity).data.tasks
    @(@($current.tasks)+@($archived)|Where-Object id -eq $Id)[0]
}
function Get-ReconcileState {
    $paths=Get-SBPendingPaths $brain -Scope $scope
    ConvertTo-SBJson @(foreach($dir in @($paths.queue,$paths.taskUpdates,$paths.receipts,$paths.discarded)){if(Test-Path -LiteralPath $dir){Get-ChildItem -LiteralPath $dir -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+'='+(Get-SBFileHash $_.FullName)}}})
}
try {
    [IO.Directory]::CreateDirectory((Join-Path $brain 'scripts'))|Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -File|Copy-Item -Destination (Join-Path $brain 'scripts')
    Write-ReconcileFile (Join-Path $brain 'VERSION') (Read-SBText (Join-Path $PSScriptRoot '../VERSION'))
    Write-ReconcileFile (Join-Path $brain 'config/shared.json') (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
    Write-ReconcileFile (Join-Path $brain 'config/tracker.schema.json') (Read-SBText (Join-Path $PSScriptRoot '../config/tracker.schema.json'))
    Write-ReconcileFile (Join-Path $brain 'directives/AGENTS.global_ide.md') '# Synthetic directives'
    Write-ReconcileFile (Join-Path $brain 'directives/workstation.template.md') '<!-- secondbrain:tracker-contract:1 -->'
    $approval=@{authorization='isolated reconcile fixture';files=@{}}
    foreach($file in @('AGENTS.global_ide.md','workstation.template.md')){$approval.files['directives/'+$file]=Get-SBFileHash (Join-Path $brain ('directives/'+$file))}
    Write-ReconcileFile (Join-Path $brain 'directives/approved.json') (ConvertTo-SBJson $approval)
    Write-ReconcileFile (Join-Path $dossier 'entity.json') (ConvertTo-SBJson @{schemaVersion=1;id='reconcile-area';kind='area';title='Reconcile';status='active'})
    Write-ReconcileFile (Join-Path $dossier 'repository.json') (ConvertTo-SBJson @{schemaVersion=1;identity=$identity;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
    Write-ReconcileFile (Join-Path $dossier 'context.md') "# Context`n"
    Write-ReconcileFile (Join-Path $dossier 'brief.md') '# Synthetic reconcile fixture'
    Write-ReconcileFile (Join-Path $dossier 'memory.md') "# Memory`n"
    Write-ReconcileFile (Join-Path $dossier 'history/seed/report.md') 'Synthetic provenance'
    $tasks=@()
    foreach($number in 1..5){
        $task=New-SBTrackerTask @{id=('T-'+$number);title=('Task '+$number);status='todo'} $identity 'fixture' 'history/seed/report.md' (Get-SBTextHash 'Synthetic provenance') 'fixture'
        $task.seq=$number;$task.title='#'+$number.ToString('000')+' '+[char]0x2014+' Task '+$number
        $tasks+=,$task
    }
    $trackerPath=Join-Path $dossier 'tracker.json'
    Write-ReconcileFile $trackerPath (ConvertTo-SBJson @{schemaVersion=1;repository=$identity;updatedAt=[DateTimeOffset]::UtcNow.ToString('o');tasks=$tasks;history=@();extensions=@{lastSeq=5}})
    [IO.Directory]::CreateDirectory($checkout)|Out-Null
    & git -c core.longpaths=true -C $checkout init -q
    & git -c core.longpaths=true -C $checkout remote add origin 'https://github.com/test/reconcile.git'
    if($LASTEXITCODE){throw 'fixture git'}
    $cfg=@{schemaVersion=1;mode='portable';brainRoot=$brain;workstationId=$hostId;runtimeRoot=$runtime;backupRoot=(Join-Path $runtime 'backups');repositoryRoot=$brain;coordinationRoot=(Join-Path $brain '.runtime/access');bindings=@(@{identity=$identity;path=$checkout;remoteIdentity=$identity});ides=@();sessionTimeoutMinutes=30;lockWaitMs=60000;configPath=$configPath}
    Write-ReconcileFile $configPath (ConvertTo-SBJson $cfg)
    function Set-ReconcileStatus([string]$Id,[string]$Status){[void](Set-SBTrackerTaskStatus -BrainRoot $brain -Identity $identity -WorkingRepository $identity -TaskId $Id -Status $Status -BackupRoot $cfg.backupRoot)}
    function New-ReconcileConflict([string]$Operation,[hashtable]$Arguments,[scriptblock]$Interfere,[switch]$Strict){
        $request=if($Strict){New-SBPendingWrite -BrainRoot $brain -Repository $identity -Operation $Operation -Arguments $Arguments -Config $cfg -StrictPreconditions}else{New-SBPendingWrite -BrainRoot $brain -Repository $identity -Operation $Operation -Arguments $Arguments -Config $cfg}
        & $Interfere
        $result=Complete-SBPendingSubmission $request $cfg
        Assert-Reconcile ($result.state -eq 'conflict') ('fixture conflict for '+$Operation+' '+$request.id)
        $request.id
    }
    # Five conflicts and one orphan receipt.
    $idApplied=New-ReconcileConflict 'task.status' @{TaskId='T-1';Status='done'} {Set-ReconcileStatus 'T-1' 'blocked'}
    Set-ReconcileStatus 'T-1' 'done'     # another writer now shows the requested value: already applied
    $idOverwrite=New-ReconcileConflict 'task.status' @{TaskId='T-2';Status='done'} {Set-ReconcileStatus 'T-2' 'blocked'}
    $idEvidence=New-ReconcileConflict 'task.update' @{TaskId='T-3';Evidence=@('history/seed/report.md|passed')} {Set-ReconcileStatus 'T-3' 'in_progress'}
    $idRetire=New-ReconcileConflict 'task.status' @{TaskId='T-4';Status='done'} {Set-ReconcileStatus 'T-4' 'blocked'}
    $idAppend=New-ReconcileConflict 'file.append' @{relativePath='history/session/report.md';content="Appended by a queued writer`n"} {Write-ReconcileFile (Join-Path $dossier 'history/session/report.md') "Other writer`n"} -Strict
    $orphanId=[guid]::NewGuid().ToString('N')
    $paths=Get-SBPendingPaths $brain -Scope $scope
    Write-ReconcileFile (Join-Path $paths.receipts ($orphanId+'.json')) (ConvertTo-SBJson @{schemaVersion=1;id=$orphanId;repository=$identity;state='applied';requestHash='x';sourceHash='x';observedAt=(Get-SBNow).ToString('o');result=@{};error=$null})
    $queueState=@{}
    foreach($entry in Get-SBPendingWrites $brain $identity){$queueState[$entry.id]=$entry.state}
    Assert-Reconcile ($queueState[$idApplied] -eq 'conflict' -and $queueState[$idAppend] -eq 'conflict') 'fixture holds conflict receipts'

    # 1. Preview: classes, safety and options; nothing written.
    $before=Get-ReconcileState
    $plan=@(Get-SBReconcilePlan $brain $identity)
    $byId=@{};foreach($item in $plan){$byId[$item.id]=$item}
    Assert-Reconcile ($plan.Count -eq 6 -and (Get-ReconcileState) -ceq $before) 'plan lists the five conflicts and the orphan receipt without writing'
    Assert-Reconcile ($byId[$idApplied].class -eq 'already-applied' -and $byId[$idApplied].safe -and $byId[$idApplied].defaultAction -eq 'retire') 'a conflict whose effect is already in the task is already-applied and safe'
    Assert-Reconcile ($byId[$idOverwrite].class -eq 'stale-hash' -and !$byId[$idOverwrite].safe -and $byId[$idOverwrite].decision.options.Count -ge 2 -and $byId[$idOverwrite].decision.question) 'a status change over an intervening edit needs a multiple-choice decision'
    Assert-Reconcile ($byId[$idEvidence].class -eq 'stale-hash' -and $byId[$idEvidence].safe -and $byId[$idEvidence].defaultAction -eq 'replan') 'an evidence-only request re-plans safely'
    Assert-Reconcile ($byId[$idAppend].class -eq 'stale-hash' -and $byId[$idAppend].safe -and $byId[$idAppend].defaultAction -eq 'replan') 'a file append re-plans safely'
    Assert-Reconcile ($byId[$orphanId].class -eq 'orphan-receipt' -and $byId[$orphanId].safe -and $byId[$orphanId].defaultAction -eq 'retire-receipt') 'a receipt without a request is an orphan'
    $summary=Get-SBPendingConflictSummary $brain $identity
    Assert-Reconcile ($summary.conflicts -eq 5 -and $summary.orphans -eq 1) 'the check summary counts conflicts and orphans'

    # 2. Decisions are validated before anything runs.
    Assert-Reconcile ((Get-ReconcileState) -ceq $before) 'preview left the queue untouched'
    $rejected=$false;try{[void](Invoke-ReconcileLocked @{Repository=$identity;Decisions=@{$idOverwrite='cancel-task'}})}catch{$rejected=$true}
    Assert-Reconcile ($rejected -and (Get-ReconcileState) -ceq $before) 'an option that is not offered is refused before any change'
    $rejected=$false;try{[void](Invoke-ReconcileLocked @{Repository=$identity;Decisions=@{('f'*32)='retire'}})}catch{$rejected=$true}
    Assert-Reconcile $rejected 'a decision for an unknown request is refused'

    # 3. -Apply: safe classes only.
    $trackerBefore=Get-SBFileHash $trackerPath
    $applied=Invoke-ReconcileLocked @{Repository=$identity;Apply=$true}
    Assert-Reconcile (@($applied.failed).Count -eq 0 -and @($applied.executed).Count -eq 4) 'apply runs the four safe items'
    $queueAfter=@{};foreach($entry in Get-SBPendingWrites $brain $identity){$queueAfter[$entry.id]=$entry}
    Assert-Reconcile (!$queueAfter.ContainsKey($idApplied) -and !$queueAfter.ContainsKey($idEvidence) -and !$queueAfter.ContainsKey($idAppend)) 'retired requests leave the queue'
    $archive=Join-Path (Get-SBPendingPaths $brain -Scope $scope).discarded $idApplied
    $note=Read-SBJson (Join-Path $archive 'discarded.json') $null
    Assert-Reconcile ((Test-Path -LiteralPath (Join-Path $archive ($idApplied+'.json'))) -and (Test-Path -LiteralPath (Join-Path $archive ($idApplied+'.receipt.json'))) -and $note.reconcile.class -eq 'already-applied') 'a retired request is moved with its receipt and a reconcile note, never deleted'
    $orphanArchive=Join-Path (Get-SBPendingPaths $brain -Scope $scope).discarded $orphanId
    Assert-Reconcile ((Test-Path -LiteralPath (Join-Path $orphanArchive ($orphanId+'.receipt.json'))) -and !(Test-Path -LiteralPath (Join-Path $paths.receipts ($orphanId+'.json')))) 'an orphan receipt is moved to pending-discarded, not deleted'
    $replaced=@($applied.executed|Where-Object {$_.ContainsKey('replacedBy')})
    Assert-Reconcile ($replaced.Count -eq 2 -and @($replaced|Where-Object {$queueAfter.ContainsKey($_.replacedBy) -and $queueAfter[$_.replacedBy].state -eq 'deferred'}).Count -eq 2) 're-planned requests are queued as new deferred requests'
    Assert-Reconcile ($queueAfter.ContainsKey($idOverwrite) -and $queueAfter[$idOverwrite].state -eq 'conflict' -and $queueAfter.ContainsKey($idRetire)) 'unsafe items are left untouched'
    Assert-Reconcile ((Get-SBFileHash $trackerPath) -ceq $trackerBefore -and (Get-ReconcileTask 'T-2').status -eq 'blocked') 'apply never writes the tracker or overwrites an intervening change'
    Assert-Reconcile ($applied.summary.decisions -eq 2 -and $applied.summary.orphans -eq 0) 'two decisions remain after apply'
    $flushed=Invoke-SBPendingWrites -BrainRoot $brain -Config $cfg -Repository $identity
    Assert-Reconcile ($flushed.applied.Count -ge 2 -and (Read-SBText (Join-Path $dossier 'history/session/report.md')).Contains('Appended by a queued writer') -and @((Get-ReconcileTask 'T-3').evidence).Count -eq 1) 'the normal flush applies the re-planned append and evidence against the current state'
    $again=Invoke-ReconcileLocked @{Repository=$identity;Apply=$true}
    Assert-Reconcile (@($again.executed).Count -eq 0) 'apply is idempotent'

    # 4. -Decide: the owner's choices.
    $decided=Invoke-ReconcileLocked @{Repository=$identity;Decisions=@{$idOverwrite='replan';$idRetire='retire'}}
    Assert-Reconcile (@($decided.failed).Count -eq 0 -and @($decided.executed).Count -eq 2) 'decide executes both choices'
    Assert-Reconcile ((Get-ReconcileTask 'T-2').status -eq 'blocked' -and (Get-ReconcileTask 'T-4').status -eq 'blocked') 'decide queues the change but does not write the tracker itself'
    [void](Invoke-SBPendingWrites -BrainRoot $brain -Config $cfg -Repository $identity)
    Assert-Reconcile ((Get-ReconcileTask 'T-2').status -eq 'done' -and (Get-ReconcileTask 'T-4').status -eq 'blocked') 'the explicitly re-planned change applies; the retired one never does'
    $final=Get-SBPendingConflictSummary $brain $identity
    Assert-Reconcile ($final.conflicts -eq 0 -and $final.orphans -eq 0 -and @(Get-SBReconcilePlan $brain $identity).Count -eq 0) 'after reconciliation nothing is reported as pending-conflict'
    Assert-Reconcile (@(1..5|Where-Object {Get-ReconcileTask ('T-'+$_)}).Count -eq 5) 'no task was deleted'

    # 5. CLI wiring: preview, bad -Decide, and -Apply of a remaining orphan inside a write session.
    $orphan2=[guid]::NewGuid().ToString('N')
    Write-ReconcileFile (Join-Path $paths.receipts ($orphan2+'.json')) (ConvertTo-SBJson @{schemaVersion=1;id=$orphan2;repository=$identity;state='applied';requestHash='x';sourceHash='x';observedAt=(Get-SBNow).ToString('o');result=@{};error=$null})
    $cliPreview=Invoke-ReconcileCli @('-Repository',$identity)
    Assert-Reconcile ($cliPreview.code -eq 0 -and $cliPreview.data.summary.orphans -eq 1 -and !$cliPreview.data.applied) 'the CLI plans by default'
    $cliBad=Invoke-ReconcileCli @('-Repository',$identity,'-Decide','not-an-id=retire')
    Assert-Reconcile ($cliBad.code -eq 2) 'the CLI rejects a malformed -Decide entry'
    $cliAll=Invoke-ReconcileCli @('-All','-Apply')
    Assert-Reconcile ($cliAll.code -ne 0) '-All only plans'
    $started=& pwsh -NoProfile -File (Join-Path $brain 'scripts/access.ps1') -ConfigPath $configPath -Start -Mode Write -Client reconcile-test -WaitSeconds 0
    $sessionId=($started|ConvertFrom-Json).sessionId
    $cliApply=Invoke-ReconcileCli @('-Repository',$identity,'-Apply','-SessionId',$sessionId)
    Assert-Reconcile ($cliApply.code -eq 0 -and $cliApply.data.applied -and @($cliApply.data.executed).Count -eq 1 -and $cliApply.data.summary.orphans -eq 0) 'the CLI applies the safe orphan retirement in a write session'
    'SUCCESS RECONCILE: '+$script:checks+' checks; fixture '+$fixture
} finally {
    if($lock){Exit-SBOperation $lock}
    if($sessionId){& pwsh -NoProfile -File (Join-Path $brain 'scripts/access.ps1') -ConfigPath $configPath -End -SessionId $sessionId|Out-Null}
}
