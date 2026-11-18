#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'trackermerge.target.missing' = @{ en = 'Dossier tracker missing: the merge needs the dossier tracker.json declared in repository.json; use the import for a dossier without a tracker' }
    'trackermerge.source.identity' = @{ en = 'Source checkout is not bound to this repository: use the tracker of the checkout bound to the identity' }
    'trackermerge.source.scope' = @{ en = 'Source checkout outside the workstation scope: use a checkout bound to this workstation' }
    'trackermerge.source.changed' = @{ en = 'Source tracker or dossier tracker modified after the preview: preview the merge again' }
    'trackermerge.plan.changed' = @{ en = 'Merge plan differs from the confirmed plan {0}: preview again and confirm the new plan hash' }
    'trackermerge.conflicts' = @{ en = 'Merge blocked by {0} unresolved conflicts: {1}; resolve them in the checkout or dossier tracker and preview again' }
    'trackermerge.archive.diverged' = @{ en = 'Source archive already exists with different bytes: {0}; review it before merging' }
    'trackermerge.backup.unverified' = @{ en = 'Tracker backup not verified: redo the backup and verify its hash' }
    'trackermerge.manifest.outside' = @{ en = 'Merge manifest outside backupRoot: use a manifest under backupRoot' }
    'trackermerge.manifest.invalid' = @{ en = 'Merge manifest invalid or of another repository: prepare a new merge' }
    'trackermerge.restore.outside' = @{ en = 'Restore outside the SecondBrain checkout: restore only recorded merge files' }
    'trackermerge.restore.refused' = @{ en = 'Restore refused: the tracker changed after the merge ({0}); review the later changes first' }
    'trackermerge.restore.unverified' = @{ en = 'Restore payload not verified: verify the backup against its hash before restoring' }
    'trackermerge.conflict.content' = @{ en = 'Task differs from the dossier task in: {0}' }
    'trackermerge.conflict.seq' = @{ en = 'Sequence number {0} already belongs to task {1}' }
    'trackermerge.conflict.history' = @{ en = 'History record {0} differs from the dossier record' }
    'trackermerge.conflict.review' = @{ en = 'Status unknown: review the task in the source before merging' }
    'trackermerge.conflict.invalid' = @{ en = 'The merged tracker would be invalid: {0}' }
    'trackermerge.issue.pending' = @{ en = 'Tracker merge pending for {0}: status={1}; add={2}; conflicts={3}; preview with import-tracker.ps1 -Merge' }
    'trackermerge.issue.failed' = @{ en = 'Tracker merge cannot be planned for {0}: {1}' }
    'trackermerge.issue.incomplete' = @{ en = 'Tracker merge incomplete: {0}; phase={1}; manifest={2}; roll it back with import-tracker.ps1 -RollbackMerge' }
    'trackermerge.issue.invalid' = @{ en = 'Tracker merge state invalid: {0}; {1}' }
}

# The checkout's own tracker, in the order Resolve-SBTracker uses: tracker.md is enough by itself; JSON
# candidates count only when they parse as an object. compatible = valid schema-1 tracker once its
# repository is realigned to the target identity (the import keeps ids, seq, evidence and provenance).
function Get-SBCheckoutTrackerSource([string]$CheckoutPath,[string]$Identity) {
    foreach($name in @('tracker.json','tracker.md','tasks.json','legacy-tasks.json')){
        $path=Join-Path $CheckoutPath $name
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        if($name -eq 'tracker.md'){return @{path=$name;compatible=$false}}
        $data=try{Read-SBJson $path $null}catch{$null}
        if($data -isnot [Collections.IDictionary]){continue}
        $compatible=$false
        if($data.Contains('schemaVersion') -and $data.schemaVersion -eq 1){
            $copy=ConvertTo-SBJson $data|ConvertFrom-Json -AsHashtable -DateKind String
            $original=if($copy.Contains('repository')){[string]$copy.repository}else{''}
            Remove-SBOriginDependencyRepository @($copy['tasks']) $original
            $copy.repository=$Identity
            $compatible=try{[bool](Test-SBTrackerData $copy $Identity @($Identity) (Join-Path $PSScriptRoot '../config/tracker.schema.json'))}catch{$false}
        }
        return @{path=$name;compatible=$compatible}
    }
    $null
}

# Canonical task text for comparison: stable key order, without the readiness assessment SecondBrain adds on import.
function ConvertTo-SBMergeTaskCanonical($Task) {
    $copy=ConvertTo-SBJson $Task|ConvertFrom-Json -AsHashtable -DateKind String
    if($copy['extensions'] -is [Collections.IDictionary] -and $copy.extensions.Contains('readiness')){[void]$copy.extensions.Remove('readiness')}
    ConvertTo-SBJson $copy
}
function Copy-SBMergeData($Value) { ConvertTo-SBJson $Value|ConvertFrom-Json -AsHashtable -DateKind String }

# Read-only plan of merging a checkout tracker into the existing dossier tracker. Task ids, seq, evidence and provenance of the
# source stay as they are; a same-id task with other content, a sequence number owned by another task, an unknown status and a
# diverging history record are conflicts and are never overwritten. Nothing is written.
function Get-SBTrackerMergePlan {
    param([string]$BrainRoot,[string]$Identity,[string]$Dossier,[string]$SourcePath)
    $targetPath=Join-Path $Dossier 'tracker.json'
    if(!(Test-Path -LiteralPath $targetPath -PathType Leaf)){throw (New-SBError 'trackermerge.target.missing')}
    Assert-SBPlainPath $targetPath
    $sourceFull=[IO.Path]::GetFullPath($SourcePath);Assert-SBPlainPath $sourceFull
    $targetBytes=[IO.File]::ReadAllBytes($targetPath);$targetHash=Get-SBHash $targetBytes
    $target=([Text.UTF8Encoding]::new($false,$true)).GetString($targetBytes).TrimStart([char]0xFEFF)|ConvertFrom-Json -AsHashtable -DateKind String
    $archive=(Read-SBTrackerArchive $targetPath $Identity).data
    $sourceHash=Get-SBFileHash $sourceFull;$name=Split-Path $sourceFull -Leaf
    $archiveDir=Join-Path $Dossier ('history/tracker-merge-'+$sourceHash.Substring(0,16).ToLowerInvariant())
    $archivePath=Join-Path $archiveDir $name
    $reference=[IO.Path]::GetRelativePath($BrainRoot,$archivePath).Replace('\','/')
    $commit='';$git=Invoke-SBGit (Split-Path $sourceFull) @('rev-parse','HEAD')
    if($git.code -eq 0){$commit=[string]@($git.output)[0]}
    $source=ConvertTo-SBTracker -SourcePath $sourceFull -Identity $Identity -Reference $reference -Commit $commit

    $existing=@{};$seqOwner=@{}
    foreach($list in @($target.tasks,$archive.tasks)){
        foreach($task in @($list)){
            $existing[[string]$task.id]=$task
            if($task.Contains('seq')){$seqOwner[[int]$task.seq]=[string]$task.id}
        }
    }
    $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if($target['extensions'] -is [Collections.IDictionary] -and $target.extensions.Contains('trackerMerges')){
        foreach($receipt in @($target.extensions.trackerMerges)){
            if($receipt -is [Collections.IDictionary] -and $receipt['tasks'] -is [Collections.IDictionary]){
                foreach($key in $receipt.tasks.Keys){[void]$known.Add($key+'|'+$receipt.tasks[$key])}
            }
        }
    }
    $added=@();$addedTasks=@();$identical=@();$already=@();$conflicts=@();$taskHashes=@{};$newSeq=@{}
    foreach($task in @($source.tasks)){
        $id=[string]$task.id;$canonical=ConvertTo-SBMergeTaskCanonical $task;$hash=Get-SBTextHash $canonical;$taskHashes[$id]=$hash
        if($existing.ContainsKey($id)){
            $current=ConvertTo-SBMergeTaskCanonical $existing[$id]
            if($current -ceq $canonical){$identical+=$id}
            elseif($known.Contains($id+'|'+$hash)){$already+=$id}
            else{
                $left=$current|ConvertFrom-Json -AsHashtable -DateKind String;$right=$canonical|ConvertFrom-Json -AsHashtable -DateKind String
                $fields=@(@($left.Keys)+@($right.Keys)|Sort-Object -Unique|Where-Object {
                    $a=if($left.Contains($_)){ConvertTo-SBJson $left[$_]}else{'<absent>'};$b=if($right.Contains($_)){ConvertTo-SBJson $right[$_]}else{'<absent>'};$a -cne $b})
                $conflicts+=@{id=$id;kind='content';fields=$fields;detail=(Get-SBMessage 'trackermerge.conflict.content' @($fields -join ', '))}
            }
            continue
        }
        if([string]$task.status -ceq 'unknown'){$conflicts+=@{id=$id;kind='review';detail=(Get-SBMessage 'trackermerge.conflict.review')};continue}
        if($task.Contains('seq')){
            $seq=[int]$task.seq
            $owner=if($seqOwner.ContainsKey($seq)){$seqOwner[$seq]}elseif($newSeq.ContainsKey($seq)){$newSeq[$seq]}else{''}
            if($owner){$conflicts+=@{id=$id;kind='seq';owner=$owner;detail=(Get-SBMessage 'trackermerge.conflict.seq' @($seq,$owner))};continue}
            $newSeq[$seq]=$id
        }
        $added+=$id;$addedTasks+=,$task
    }
    $targetHistory=@($target['history'])
    $newHistory=@()
    foreach($record in @($source['history'])){
        $key=[string]$record['reference'];$text=ConvertTo-SBJson $record
        $same=@($targetHistory|Where-Object {[string]$_['reference'] -ceq $key})
        if(!$same.Count){if(!@($newHistory|Where-Object {(ConvertTo-SBJson $_) -ceq $text}).Count){$newHistory+=,$record}}
        elseif(!@($same|Where-Object {(ConvertTo-SBJson $_) -ceq $text}).Count){$conflicts+=@{id=$key;kind='history';detail=(Get-SBMessage 'trackermerge.conflict.history' @($key))}}
    }
    $candidate=$null
    if($added.Count -or $newHistory.Count){
        $candidate=Copy-SBMergeData $target
        if($candidate['extensions'] -isnot [Collections.IDictionary]){$candidate.extensions=@{}}
        $candidate.tasks=@(@($candidate.tasks)+@($addedTasks|ForEach-Object {Copy-SBMergeData $_}))
        $mergeNote=ConvertTo-SBTrackerHistoryRecord @{reference=$reference;sha256=$sourceHash;description=('Merged checkout tracker '+$name+': '+$added.Count+' tasks added')}
        $candidate.history=@(@($candidate.history)+@($newHistory|ForEach-Object {Copy-SBMergeData $_})+@($mergeNote))
        $last=[Math]::Max((Get-SBTrackerLastSeq @{tasks=@($candidate.tasks)+@($archive.tasks);extensions=$candidate.extensions}),$(if($source['extensions'] -is [Collections.IDictionary] -and $source.extensions.Contains('lastSeq')){[int]$source.extensions.lastSeq}else{0}))
        if($last -gt 0){$candidate.extensions.lastSeq=$last}
        if(!$conflicts.Count){
            try{Assert-SBTrackerWriteData $BrainRoot $Identity $candidate $targetPath}
            catch{$conflicts+=@{id='*';kind='invalid';detail=(Get-SBMessage 'trackermerge.conflict.invalid' @($_.Exception.Message))}}
        }
    }
    $status=if($conflicts.Count){'conflicts'}elseif($added.Count -or $newHistory.Count){'ready'}else{'up-to-date'}
    $summary=@{identity=$Identity;status=$status;source=@{path=$name;sha256=$sourceHash;tasks=@($source.tasks).Count};target=@{path='tracker.json';sha256=$targetHash}
        added=@($added);identical=@($identical);alreadyMerged=@($already);conflicts=@($conflicts);historyAdded=$newHistory.Count
        planSha256=(Get-SBTextHash ($sourceHash+'|'+$targetHash+'|'+$Identity+'|'+$status))}
    @{summary=$summary;candidate=$candidate;targetPath=$targetPath;sourcePath=$sourceFull;sourceHash=$sourceHash;targetHash=$targetHash;archiveDir=$archiveDir;archivePath=$archivePath;taskHashes=$taskHashes;name=$name}
}

function Read-SBTrackerMergeManifest($Config,[string]$Path) {
    $boundary=[IO.Path]::GetFullPath($Config.backupRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $full=[IO.Path]::GetFullPath($Path);Assert-SBPlainPath $full
    if(!$full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'trackermerge.manifest.outside')}
    $m=Read-SBJson $full $null
    if(!$m -or $m.schemaVersion -ne 1 -or $m.kind -cne 'tracker-merge' -or $m.brainRoot -ne $Config.brainRoot -or $m.id -notmatch '^[a-f0-9]{32}$' -or
       !(Test-SBRepositoryIdentity $m.identity $Config.allowedOwners) -or $m.phase -notin @('prepared','completed','rolled_back')){throw (New-SBError 'trackermerge.manifest.invalid')}
    $dir=Resolve-SBParaPath $Config.brainRoot $m.dossier
    if($m.target.path -ne (Join-Path $dir 'tracker.json') -or $full -ne (Join-Path $Config.backupRoot ('tracker-merge-'+$m.id+'/manifest.json'))){throw (New-SBError 'trackermerge.manifest.invalid')}
    $m
}

# Applies a previewed plan: backup of the dossier tracker, one PARA transaction for tracker and source archive, journal under backupRoot.
# The caller holds the write operation. PlanSha256 is the explicit confirmation of the previewed plan.
function Invoke-SBTrackerMerge {
    param($Config,[string]$Identity,[string]$SourcePath,[string]$PlanSha256)
    $resolved=Resolve-SBTracker -BrainRoot $Config.brainRoot -Identity $Identity -AllowedOwners $Config.allowedOwners
    if(!$resolved.declared){throw (New-SBError 'trackermerge.target.missing')}
    $dossier=Split-Path $resolved.path
    $checkout=Split-Path ([IO.Path]::GetFullPath($SourcePath))
    if(!(Test-SBCheckoutScope $Config $checkout)){throw (New-SBError 'trackermerge.source.scope')}
    $bindings=if($Config.ContainsKey('bindings')){$Config.bindings}else{@()}
    if((Resolve-SBBoundIdentity $checkout $bindings) -cne $Identity){throw (New-SBError 'trackermerge.source.identity')}
    $plan=Get-SBTrackerMergePlan $Config.brainRoot $Identity $dossier $SourcePath
    $summary=$plan.summary
    if(!$PlanSha256 -or $summary.planSha256 -cne $PlanSha256){throw (New-SBError 'trackermerge.plan.changed' @($PlanSha256))}
    if($summary.conflicts.Count){throw (New-SBError 'trackermerge.conflicts' @($summary.conflicts.Count,(@($summary.conflicts|ForEach-Object {$_.id+' ('+$_.kind+')'}) -join ', ')))}
    if($summary.status -ceq 'up-to-date'){return $null}
    $id=New-SBId;$journal=Join-Path $Config.backupRoot ('tracker-merge-'+$id);$manifestPath=Join-Path $journal 'manifest.json'
    $candidate=$plan.candidate
    $candidate.extensions.trackerMerges=@(@(if($candidate.extensions.Contains('trackerMerges')){$candidate.extensions.trackerMerges})+@(@{id=$id;source=$plan.name;sourceSha256=$plan.sourceHash;archive=[IO.Path]::GetRelativePath($Config.brainRoot,$plan.archivePath).Replace('\','/');mergedAt=(Get-SBNow).ToString('o');tasks=$plan.taskHashes}))
    $candidate.updatedAt=(Get-SBNow).ToString('o')
    Assert-SBTrackerWriteData $Config.brainRoot $Identity $candidate $plan.targetPath
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $candidate))
    $sourceBytes=[IO.File]::ReadAllBytes($plan.sourcePath)
    if((Get-SBHash $sourceBytes) -cne $plan.sourceHash -or (Get-SBFileHash $plan.targetPath) -cne $plan.targetHash){throw (New-SBError 'trackermerge.source.changed')}
    $operations=@(@{path=$plan.targetPath;expected=$plan.targetHash;bytes=$bytes});$created=@()
    $archiveHash=Get-SBFileHash $plan.archivePath
    if($archiveHash -eq 'absent'){$operations+=@{path=$plan.archivePath;expected='absent';bytes=$sourceBytes};$created+=$plan.archivePath}
    elseif($archiveHash -cne $plan.sourceHash){throw (New-SBError 'trackermerge.archive.diverged' @($plan.archivePath))}
    $attributes=Join-Path $plan.archiveDir '.gitattributes'
    if((Get-SBFileHash $attributes) -eq 'absent'){$operations+=@{path=$attributes;expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes("* -text`n")};$created+=$attributes}
    foreach($operation in $operations){if($operation.expected -eq 'absent'){[void][IO.Directory]::CreateDirectory((Split-Path $operation.path))}}
    $backup=Join-Path $journal 'target.bin'
    [void](Write-SBFile $backup ([IO.File]::ReadAllBytes($plan.targetPath)) 'absent' $Config.backupRoot)
    if((Get-SBFileHash $backup) -cne $plan.targetHash){throw (New-SBError 'trackermerge.backup.unverified')}
    $m=@{schemaVersion=1;kind='tracker-merge';id=$id;identity=$Identity;brainRoot=$Config.brainRoot;dossier=[IO.Path]::GetRelativePath($Config.brainRoot,$dossier).Replace('\','/');phase='prepared';lastError=$null
        source=@{path=$plan.sourcePath;sha256=$plan.sourceHash;archive=$plan.archivePath};target=@{path=$plan.targetPath;previousHash=$plan.targetHash;deployedHash=(Get-SBHash $bytes);backup=$backup}
        created=@($created);added=@($summary.added);planSha256=$summary.planSha256;createdAt=(Get-SBNow).ToString('o')}
    [void](Write-SBFile $manifestPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))) 'absent' $Config.backupRoot)
    try{
        [void](Invoke-SBParaTransaction -Operations $operations -BackupRoot $Config.backupRoot -BrainRoot $Config.brainRoot)
        $m.phase='completed'
    }catch{
        $m.lastError=$_.Exception.Message
        [void](Write-SBFile $manifestPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))) (Get-SBFileHash $manifestPath) $Config.backupRoot)
        throw
    }
    [void](Write-SBFile $manifestPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))) (Get-SBFileHash $manifestPath) $Config.backupRoot)
    $manifestPath
}

# Rollback: restores the verified backup of the dossier tracker and removes the files the merge created, refusing when the tracker
# changed after the merge. The checkout tracker is never touched by merge or rollback.
function Restore-SBTrackerMerge($Config,[string]$ManifestPath) {
    $m=Read-SBTrackerMergeManifest $Config $ManifestPath
    if($m.phase -eq 'rolled_back'){return}
    $boundary=$Config.brainRoot.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach($path in @($m.target.path)+@($m.created)){
        if(!([IO.Path]::GetFullPath($path)).StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'trackermerge.restore.outside')}
        Assert-SBPlainPath $path
    }
    $current=Get-SBFileHash $m.target.path
    if($current -notin @($m.target.previousHash,$m.target.deployedHash)){throw (New-SBError 'trackermerge.restore.refused' @($m.target.path))}
    Assert-SBPlainPath $m.target.backup
    if((Get-SBFileHash $m.target.backup) -cne $m.target.previousHash){throw (New-SBError 'trackermerge.restore.unverified')}
    if($current -ne $m.target.previousHash){[void](Write-SBFile $m.target.path ([IO.File]::ReadAllBytes($m.target.backup)) $current $Config.backupRoot)}
    foreach($path in @($m.created)){
        $hash=Get-SBFileHash $path
        if($hash -ne 'absent'){[void](Remove-SBFile $path $Config.brainRoot $hash $Config.backupRoot)}
    }
    $m.phase='rolled_back';$m.lastError=$null
    [void](Write-SBFile $ManifestPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))) (Get-SBFileHash $ManifestPath) $Config.backupRoot)
}

# sb check: merge journals that did not complete, and bound repositories whose checkout tracker still has unmerged tasks or conflicts.
function Get-SBTrackerMergeIssues($Config) {
    $root=$Config.backupRoot
    if(Test-Path -LiteralPath $root -PathType Container){
        foreach($entry in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'tracker-merge-*')){
            $manifestPath=Join-Path $entry.FullName 'manifest.json'
            try{
                if(!(Test-Path -LiteralPath $manifestPath -PathType Leaf)){continue}
                $m=Read-SBTrackerMergeManifest $Config $manifestPath
                if($m.phase -eq 'prepared'){Get-SBMessage 'trackermerge.issue.incomplete' @($m.identity,$m.phase,$manifestPath)}
            }catch{Get-SBMessage 'trackermerge.issue.invalid' @($entry.FullName,$_.Exception.Message)}
        }
    }
    $entities=@(Get-SBParaEntities $Config.brainRoot $Config.allowedOwners)
    foreach($binding in @($Config.bindings)){
        if((Get-SBBindingStatus $binding) -ne 'managed' -or !(Test-Path -LiteralPath $binding.path -PathType Container)){continue}
        $areas=@($entities|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and $_.status -eq 'active' -and $_.repository -ceq $binding.identity})
        if($areas.Count -ne 1){continue}
        $dir=Resolve-SBParaPath $Config.brainRoot $areas[0].path
        $record=Read-SBJson (Join-Path $dir 'repository.json') @{}
        if(!$record.ContainsKey('tracker') -or !(Test-Path -LiteralPath (Join-Path $dir 'tracker.json') -PathType Leaf)){continue}
        $source=Get-SBCheckoutTrackerSource $binding.path $binding.identity
        if(!$source){continue}
        try{
            $summary=(Get-SBTrackerMergePlan $Config.brainRoot $binding.identity $dir (Join-Path $binding.path $source.path)).summary
            if($summary.status -ne 'up-to-date'){Get-SBMessage 'trackermerge.issue.pending' @($binding.identity,$summary.status,$summary.added.Count,$summary.conflicts.Count)}
        }catch{Get-SBMessage 'trackermerge.issue.failed' @($binding.identity,$_.Exception.Message)}
    }
}

Export-ModuleMember -Function @(
    'Get-SBCheckoutTrackerSource',
    'Get-SBTrackerMergePlan',
    'Read-SBTrackerMergeManifest',
    'Invoke-SBTrackerMerge',
    'Restore-SBTrackerMerge',
    'Get-SBTrackerMergeIssues'
)
