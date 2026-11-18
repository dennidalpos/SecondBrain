#requires -Version 7.5
# #706: verify and reconcile queued writes (conflict / invalid requests and orphan receipts) per repository.
# Plan-only by default. Safe classes are applied with -Apply; everything else returns a multiple-choice decision answered with -Decide.
# Nothing is ever deleted: requests and receipts move to pending-discarded/<scope>/<id>/ with a note; "removing" a task means status cancelled.
Set-StrictMode -Version Latest
foreach($m in 'Core','Access','Host','Pending','Tracker','Knowledge','Para'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'reconcile.decide.invalid' = @{ en = 'Invalid -Decide entry "{0}": use <request id>=<option>' }
    'reconcile.decide.unknown' = @{ en = 'No reconcilable item for request {0}' }
    'reconcile.option.invalid' = @{ en = 'Option "{0}" is not offered for request {1}: choose one of {2}' }
    'reconcile.orphan.live' = @{ en = 'Receipt {0} has a request again: it is not an orphan' }
    'reconcile.next.flush' = @{ en = 'New requests were queued: integrate them with knowledge.ps1 -FlushPending' }
    'reconcile.question' = @{ en = 'What should happen to the queued {0} {1}: {2}?' }
    'reconcile.reason.already-applied' = @{ en = 'its effect is already in the dossier' }
    'reconcile.reason.stale-safe' = @{ en = 'the task or file moved on, and the request only adds data (or nothing changed): it can be re-planned against the current state' }
    'reconcile.reason.stale-overwrite' = @{ en = 'the task or file changed since the request was made, and applying it would overwrite those changes' }
    'reconcile.reason.task-missing' = @{ en = 'the target task no longer exists' }
    'reconcile.reason.id-collision' = @{ en = 'a different task already has the requested ID' }
    'reconcile.reason.provenance' = @{ en = 'the provenance file changed or is missing' }
    'reconcile.reason.invalid' = @{ en = 'the request is invalid and was never applied' }
    'reconcile.reason.invalid-request' = @{ en = 'the request file is unreadable or breaks the schema' }
    'reconcile.reason.no-dossier' = @{ en = 'the repository has no single active dossier' }
    'reconcile.reason.orphan' = @{ en = 'the receipt has no request any more' }
    'reconcile.opt.retire' = @{ en = 'Retire the request' }
    'reconcile.opt.retire.desc' = @{ en = 'Moves request and receipt to pending-discarded with a note; nothing is deleted or applied.' }
    'reconcile.opt.replan' = @{ en = 'Re-plan against the current state' }
    'reconcile.opt.replan.desc' = @{ en = 'Queues a new request with current preconditions and retires the old one; the new one is applied by the normal flush and may overwrite the intervening change.' }
    'reconcile.opt.keep' = @{ en = 'Keep it as it is' }
    'reconcile.opt.keep.desc' = @{ en = 'Leaves the request and its receipt untouched.' }
    'reconcile.opt.cancel' = @{ en = 'Cancel the target task' }
    'reconcile.opt.cancel.desc' = @{ en = 'Queues status cancelled for the target task (never a deletion) and retires the request.' }
    'reconcile.opt.receipt' = @{ en = 'Retire the receipt' }
    'reconcile.opt.receipt.desc' = @{ en = 'Moves the orphan receipt to pending-discarded with a note; nothing is deleted.' }
}
function New-SBReconcileOption([string]$Id) {
    $key=switch($Id){'retire'{'retire'}'replan'{'replan'}'keep'{'keep'}'cancel-task'{'cancel'}'retire-receipt'{'receipt'}}
    @{id=$Id;label=(Get-SBMessage ('reconcile.opt.'+$key));description=(Get-SBMessage ('reconcile.opt.'+$key+'.desc'))}
}
function ConvertTo-SBReconcileEvidenceKeys($Items) {
    @(foreach($item in @($Items)){
        if($item -is [Collections.IDictionary]){[string]$item['reference']+'|'+[string]$item['outcome']}
        else{
            $parts=([string]$item) -split '\|',2
            $parts[0].Trim()+'|'+$(if($parts.Count -eq 2){$parts[1].Trim()}else{'unverified'})
        }
    })
}
function Test-SBReconcileApplied($Request,$Task) {
    # Evidence is a plain append: it is applied when every requested reference|outcome is already on the task. Other fields use the pending primitive.
    $arguments=$Request.arguments
    if($arguments.ContainsKey('Evidence')){
        $have=@(ConvertTo-SBReconcileEvidenceKeys $(if($Task.ContainsKey('evidence')){$Task.evidence}else{@()}))
        if(@(ConvertTo-SBReconcileEvidenceKeys $arguments.Evidence|Where-Object {$_ -cnotin $have}).Count){return $false}
        $rest=@{}+$arguments;$rest.Remove('Evidence')
        if(@($rest.Keys|Where-Object {$_ -notin @('TaskId','Executor')}).Count -eq 0){return $true}
        return (Test-SBPendingAlreadyApplied @{arguments=$rest} $Task)
    }
    Test-SBPendingAlreadyApplied $Request $Task
}
function Get-SBReconcileOrphans([string]$BrainRoot,[string]$Scope) {
    $paths=Get-SBPendingPaths $BrainRoot -Scope $Scope
    if(![IO.Directory]::Exists($paths.receipts)){return @()}
    @(foreach($file in Get-ChildItem -LiteralPath $paths.receipts -Filter '*.json' -File|Sort-Object Name){
        $id=$file.BaseName
        if($id -cnotmatch '^[a-f0-9]{32}$'){continue}
        if([IO.File]::Exists((Join-Path $paths.queue ($id+'.json'))) -or [IO.File]::Exists((Join-Path $paths.taskUpdates ($id+'.json')))){continue}
        $repository=$null
        try{$receipt=Read-SBJson $file.FullName $null;if($receipt -is [Collections.IDictionary] -and $receipt.ContainsKey('repository')){$repository=[string]$receipt.repository}}catch{Write-Verbose $_.Exception.Message}
        @{id=$id;scope=$Scope;repository=$repository;receiptPath=$file.FullName}
    })
}
function New-SBReconcileItem($Entry,[string]$Class,[bool]$Safe,[string]$DefaultAction,[string[]]$Options,[string]$Reason,[string]$TaskId='') {
    $item=@{id=$Entry.id;scope=$Entry.scope;repository=$Entry.repository;state=$Entry.state;operation=$Entry.operation;taskId=$TaskId;class=$Class;safe=$Safe;
        defaultAction=$DefaultAction;reason=(Get-SBMessage ('reconcile.reason.'+$Reason));options=@($Options|ForEach-Object {New-SBReconcileOption $_})}
    if(!$Safe){
        $target=if($TaskId){$TaskId}else{[string]$Entry.operation}
        $item.decision=@{question=(Get-SBMessage 'reconcile.question' @($Entry.operation,$target,$item.reason));options=@($item.options)}
    }
    $item
}
function Get-SBReconcileClassification($BrainRoot,$Entry,$Context) {
    # Classifies one queued request whose receipt is conflict, invalid or invalid-receipt. Read-only.
    $request=$null
    try{$request=Read-SBJson $Entry.path $null;Assert-SBPendingRequest $request $Entry.id}catch{
        $Entry.operation='?'
        return (New-SBReconcileItem $Entry 'invalid-request' $false 'keep' @('retire','keep') 'invalid-request')
    }
    $Entry.operation=[string]$request.operation;$Entry.repository=[string]$request.repository
    $taskId=if($request.arguments.ContainsKey('TaskId')){[string]$request.arguments.TaskId}elseif($request.arguments.ContainsKey('Id')){[string]$request.arguments.Id}else{''}
    if($Entry.state -in @('invalid','invalid-receipt')){
        $options=@('retire','keep')
        if($taskId -and $request.operation -like 'task.*' -and $request.operation -ne 'task.new'){$options=@('retire','cancel-task','keep')}
        return (New-SBReconcileItem $Entry 'invalid' $false 'keep' $options 'invalid' $taskId)
    }
    $dossier=$null
    try{
        if(!$Context.dossiers.ContainsKey($request.repository)){$Context.dossiers[$request.repository]=Resolve-SBPendingDossier $BrainRoot $request.repository}
        $dossier=$Context.dossiers[$request.repository]
    }catch{return (New-SBReconcileItem $Entry 'no-dossier' $false 'keep' @('retire','keep') 'no-dossier' $taskId)}
    if($request.operation -like 'task.*'){
        if(!$Context.trackers.ContainsKey($request.repository)){
            $target=Read-SBPendingTracker $BrainRoot $request.repository $dossier
            $Context.trackers[$request.repository]=@{tracker=$target;tasks=@(@($target.data.tasks)+@((Read-SBTrackerArchive $target.path $request.repository).data.tasks))}
        }
        $known=$Context.trackers[$request.repository]
    }
    switch($request.operation){
        {$_ -in @('task.status','task.update')} {
            $task=@($known.tasks|Where-Object id -eq $taskId)
            if($task.Count -ne 1){return (New-SBReconcileItem $Entry 'task-missing' $false 'keep' @('retire','keep') 'task-missing' $taskId)}
            if(Test-SBReconcileApplied $request $task[0]){return (New-SBReconcileItem $Entry 'already-applied' $true 'retire' @('retire','keep') 'already-applied' $taskId)}
            $hashNow=Get-SBTextHash (ConvertTo-SBJson $task[0])
            $evidenceOnly=!@($request.arguments.Keys|Where-Object {$_ -notin @('TaskId','Evidence','Executor')}).Count
            if($hashNow -ieq $request.expected.taskHash -or $evidenceOnly){return (New-SBReconcileItem $Entry 'stale-hash' $true 'replan' @('replan','retire','keep') 'stale-safe' $taskId)}
            return (New-SBReconcileItem $Entry 'stale-hash' $false 'keep' @('replan','retire','keep') 'stale-overwrite' $taskId)
        }
        'task.new' {
            $existing=@($known.tasks|Where-Object {$request.arguments.ContainsKey('Id') -and $request.arguments.Id -and $_.id -ceq $request.arguments.Id})
            if($existing.Count){
                if(([string]$existing[0].title).EndsWith([string]$request.arguments.Title,[StringComparison]::Ordinal)){return (New-SBReconcileItem $Entry 'already-applied' $true 'retire' @('retire','keep') 'already-applied' $taskId)}
                return (New-SBReconcileItem $Entry 'id-collision' $false 'keep' @('retire','keep') 'id-collision' $taskId)
            }
            $source=$null
            try{$source=Resolve-SBParaPath $BrainRoot $request.expected.provenancePath}catch{Write-Verbose $_.Exception.Message}
            if(!$source -or (Get-SBFileHash $source) -ine $request.expected.provenanceHash){return (New-SBReconcileItem $Entry 'provenance-changed' $false 'keep' @('replan','retire','keep') 'provenance' $taskId)}
            return (New-SBReconcileItem $Entry 'stale-hash' $true 'replan' @('replan','retire','keep') 'stale-safe' $taskId)
        }
        default {
            $path=Resolve-SBParaPath $dossier $request.arguments.relativePath
            $current=if([IO.File]::Exists($path)){Read-SBText $path}else{$null}
            $content=[string]$request.arguments.content
            $applied=if($request.operation -eq 'file.save'){$null -ne $current -and $current -ceq $content}else{$null -ne $current -and $content.Length -gt 0 -and $current.Contains($content)}
            if($applied){return (New-SBReconcileItem $Entry 'already-applied' $true 'retire' @('retire','keep') 'already-applied')}
            # An append never loses data, so it re-plans safely; a save would overwrite what changed, so it asks.
            if($request.operation -eq 'file.append'){return (New-SBReconcileItem $Entry 'stale-hash' $true 'replan' @('replan','retire','keep') 'stale-safe')}
            return (New-SBReconcileItem $Entry 'stale-hash' $false 'keep' @('replan','retire','keep') 'stale-overwrite')
        }
    }
}
function Get-SBReconcilePlan {
    # Read-only: every conflict/invalid request and orphan receipt of the repository (or of every scope), with class, safety and options.
    param([string]$BrainRoot,[string]$Repository)
    $scopes=if($Repository){@(Get-SBScopeKey $Repository)}else{@(Get-SBPendingScopes $BrainRoot)}
    $context=@{dossiers=@{};trackers=@{}}
    $items=@()
    foreach($scope in $scopes){
        $queued=@(Get-SBPendingScopeWrites $BrainRoot $scope)
        foreach($entry in $queued|Where-Object {$_.state -in @('conflict','invalid','invalid-receipt')}){
            $record=@{id=$entry.id;scope=$scope;repository=$entry.repository;state=$entry.state;path=$entry.path;operation=''}
            $items+=,(Get-SBReconcileClassification $BrainRoot $record $context)
        }
        foreach($orphan in @(Get-SBReconcileOrphans $BrainRoot $scope)){
            $record=@{id=$orphan.id;scope=$scope;repository=$orphan.repository;state='orphan-receipt';operation='receipt'}
            $items+=,(New-SBReconcileItem $record 'orphan-receipt' $true 'retire-receipt' @('retire-receipt','keep') 'orphan')
        }
    }
    @($items)
}
function Move-SBOrphanReceipt {
    param([string]$BrainRoot,[string]$Scope,[string]$Id,[hashtable]$Extra=@{})
    if($Id -cnotmatch '^[a-f0-9]{32}$'){throw (New-SBError 'pending.invalid' @('request ID'))}
    Assert-SBWriteGuard
    $paths=Get-SBPendingPaths $BrainRoot -Scope $Scope
    $receipt=Join-Path $paths.receipts ($Id+'.json')
    Assert-SBPlainPath $receipt
    if(![IO.File]::Exists($receipt)){throw (New-SBError 'pending.discard.notfound')}
    if([IO.File]::Exists((Join-Path $paths.queue ($Id+'.json'))) -or [IO.File]::Exists((Join-Path $paths.taskUpdates ($Id+'.json')))){throw (New-SBError 'reconcile.orphan.live' @($Id))}
    $target=Join-Path $paths.discarded $Id
    Assert-SBPlainPath $target
    [IO.Directory]::CreateDirectory($target)|Out-Null
    $note=@{schemaVersion=1;id=$Id;state='orphan-receipt';receiptHash=(Get-SBFileHash $receipt);discardedAt=(Get-SBNow).ToString('o')}
    foreach($key in $Extra.Keys){if($key -notin $note.Keys){$note[$key]=$Extra[$key]}}
    $noteName=if([IO.File]::Exists((Join-Path $target 'discarded.json'))){'orphan-receipt.json'}else{'discarded.json'}
    $receiptName=if([IO.File]::Exists((Join-Path $target ($Id+'.receipt.json')))){$Id+'.orphan.receipt.json'}else{$Id+'.receipt.json'}
    [IO.File]::WriteAllText((Join-Path $target $noteName),(ConvertTo-SBJson $note),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $receipt -Destination (Join-Path $target $receiptName)
    @{id=$Id;state='discarded';previousState='orphan-receipt';archive=$target}
}
function Get-SBReconcileRequestPath([string]$BrainRoot,[string]$Scope,[string]$Id) {
    $paths=Get-SBPendingPaths $BrainRoot -Scope $Scope
    foreach($directory in @($paths.queue,$paths.taskUpdates)){
        $candidate=Join-Path $directory ($Id+'.json')
        if([IO.File]::Exists($candidate)){return $candidate}
    }
    throw (New-SBError 'pending.discard.notfound')
}
function Submit-SBReconcileRequest($BrainRoot,$Config,[string]$Repository,[string]$SessionId,[string]$Operation,[hashtable]$Arguments,[hashtable]$Expected,[bool]$Strict) {
    $call=@{BrainRoot=$BrainRoot;Repository=$Repository;Operation=$Operation;Arguments=$Arguments;Config=$Config}
    if($Expected){$call.Expected=$Expected}
    if($SessionId){$call.SessionId=$SessionId}
    if($Strict){$call.StrictPreconditions=$true}
    New-SBPendingWrite @call
}
function Invoke-SBReconcileAction($BrainRoot,$Config,$Item,[string]$Action,[string]$SessionId) {
    $extra=@{reconcile=@{class=$Item.class;action=$Action}}
    switch($Action){
        'retire' {return (Move-SBPendingConflict -BrainRoot $BrainRoot -Id $Item.id -Repository $Item.repository -Extra $extra)}
        'retire-receipt' {return (Move-SBOrphanReceipt -BrainRoot $BrainRoot -Scope $Item.scope -Id $Item.id -Extra $extra)}
        'cancel-task' {
            $reason='Cancelled by reconcile-tasks: request '+$Item.id+' could not be applied'
            $new=Submit-SBReconcileRequest $BrainRoot $Config $Item.repository $SessionId 'task.status' @{TaskId=$Item.taskId;Status='cancelled';StateReason=$reason} $null $false
            $extra.reconcile.replacedBy=$new.id
            $retired=Move-SBPendingConflict -BrainRoot $BrainRoot -Id $Item.id -Repository $Item.repository -Extra $extra
            return @{id=$Item.id;state='discarded';action=$Action;replacedBy=$new.id;archive=$retired.archive}
        }
        'replan' {
            $request=Read-SBJson (Get-SBReconcileRequestPath $BrainRoot $Item.scope $Item.id) $null
            $arguments=@{}+$request.arguments
            $new=switch($request.operation){
                {$_ -in @('task.status','task.update')} {Submit-SBReconcileRequest $BrainRoot $Config $Item.repository $SessionId $request.operation $arguments $null $false}
                'task.new' {Submit-SBReconcileRequest $BrainRoot $Config $Item.repository $SessionId 'task.new' $arguments $null ([bool]$request.expected.ContainsKey('trackerHash'))}
                'file.append' {Submit-SBReconcileRequest $BrainRoot $Config $Item.repository $SessionId 'file.append' $arguments $null $true}
                'file.save' {
                    $dossier=Resolve-SBPendingDossier $BrainRoot $Item.repository
                    Submit-SBReconcileRequest $BrainRoot $Config $Item.repository $SessionId 'file.save' $arguments @{hash=(Get-SBFileHash (Resolve-SBParaPath $dossier $request.arguments.relativePath))} $false
                }
                default {throw (New-SBError 'pending.invalid' @('operation'))}
            }
            $extra.reconcile.replacedBy=$new.id
            $retired=Move-SBPendingConflict -BrainRoot $BrainRoot -Id $Item.id -Repository $Item.repository -Extra $extra
            return @{id=$Item.id;state='discarded';action=$Action;replacedBy=$new.id;archive=$retired.archive}
        }
        default {throw (New-SBError 'reconcile.option.invalid' @($Action,$Item.id,'retire, replan, cancel-task, retire-receipt, keep'))}
    }
}
function Invoke-SBReconcile {
    # Plan, then (with -Apply) execute the safe items' default actions and (with -Decisions) the user's choices; items with no choice stay as they are.
    param([string]$BrainRoot,$Config,[string]$Repository,[switch]$Apply,[hashtable]$Decisions=@{},[string]$SessionId)
    $items=@(Get-SBReconcilePlan $BrainRoot $Repository)
    foreach($id in $Decisions.Keys){
        $item=@($items|Where-Object id -ceq $id)
        if($item.Count -ne 1){throw (New-SBError 'reconcile.decide.unknown' @($id))}
        if($Decisions[$id] -cnotin @($item[0].options|ForEach-Object id)){throw (New-SBError 'reconcile.option.invalid' @($Decisions[$id],$id,((@($item[0].options|ForEach-Object id)) -join ', ')))}
    }
    $executed=@();$failed=@();$kept=@()
    foreach($item in $items){
        $choice=if($Decisions.ContainsKey($item.id)){$Decisions[$item.id]}elseif($Apply -and $item.safe){$item.defaultAction}else{$null}
        if(!$choice){continue}
        if($choice -ceq 'keep'){$kept+=$item.id;continue}
        try{$executed+=,(Invoke-SBReconcileAction $BrainRoot $Config $item $choice $SessionId)}
        catch{$failed+=@{id=$item.id;action=$choice;error=$_.Exception.Message}}
    }
    $acted=($Apply -or $Decisions.Count) -and ($executed.Count -or $failed.Count)
    $after=if($acted){@(Get-SBReconcilePlan $BrainRoot $Repository)}else{$items}
    @{schemaVersion=1;repository=$Repository;applied=[bool]($Apply -or $Decisions.Count);
      summary=@{conflicts=@($after|Where-Object {$_.class -ne 'orphan-receipt'}).Count;orphans=@($after|Where-Object {$_.class -eq 'orphan-receipt'}).Count;
          safe=@($after|Where-Object safe).Count;decisions=@($after|Where-Object {!$_.safe}).Count};
      items=@($items|ForEach-Object {@{} + $_});executed=@($executed);kept=@($kept);failed=@($failed);
      next=$(if(@($executed|Where-Object {$_.ContainsKey('replacedBy')}).Count){(Get-SBMessage 'reconcile.next.flush')}else{''})}
}
Export-ModuleMember -Function Get-SBReconcilePlan,Invoke-SBReconcile,Move-SBOrphanReceipt
