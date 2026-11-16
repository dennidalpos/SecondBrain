#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.ComputerUse.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TaskLedger.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Decisions.psm1')
Add-SBMessages @{
    'tracker.batch.empty' = @{ en = 'Empty update batch: the file must list at least one update' }
    'tracker.batch.item' = @{ en = 'Update {0} ({1}) refused, tracker unchanged: {2}' }
    'tracker.batch.shape' = @{ en = 'Each update is an object with taskId and at least one field' }
    'tracker.batch.duplicate' = @{ en = 'The task already appears in an earlier update of the batch: merge the fields into one entry' }
    'tracker.batch.changed' = @{ en = 'The tracker changed after the batch was prepared: run the command again' }
    'tracker.update.empty' = @{ en = 'Specify at least one field to update: -Status, -Priority, -Execution, -DependsOn, -Stream, -Awaiting, -Requires, -StateReason, -Description, -Acceptance, -Decisions or -Evidence' }
    'tracker.decisions.invalid' = @{ en = 'Invalid decisions: every entry needs question and answer (text); fix the decisions JSON file' }
    'tracker.evidence.correction.invalid' = @{ en = 'Invalid evidence correction: give a reason (up to 1024 characters) and at most 100 reference|outcome entries, and do not combine it with appended evidence' }
    'tracker.evidence.invalid' = @{ en = 'Invalid evidence: use reference|outcome with outcome passed, failed, partial or unverified; entries are separated by semicolons and each needs |outcome, so a reference cannot contain a semicolon; evidence is append-only' }
    'tracker.priority.invalid' = @{ en = 'Invalid priority: use P0, P1, P2, P3 or P4' }
    'tracker.execution.invalid' = @{ en = 'Invalid execution mode: use autonomous, user_required or unspecified' }
    'tracker.requires.invalid' = @{ en = 'Invalid required capability: {0} (allowed: {1})' }
    'tracker.closure.advice' = @{ en = 'Update memory and context, offer a minimal summary (memory, history or skip), then run Sync and Check.' }
    'tracker.closure.invalid' = @{ en = 'Invalid tracker closure metadata: fix extensions.closure or remove it' }
    'tracker.history.note' = @{ en = 'Original note: {0}' }
    'tracker.history.dependencies' = @{ en = 'Explicit historical outcomes used to resolve dependencies' }
    'tracker.history.numbered' = @{ en = 'Retroactive numbering: {0} tasks (archived and active) in chronological order; originals preserved by hash.' }
    'tracker.reason.numbered' = @{ en = 'Tracker already numbered' }
    'tracker.history.snapshot' = @{ en = 'History original does not match: {0}; restore it from the backup or regenerate the history' }
    'tracker.seq.duplicate' = @{ en = 'Duplicate sequence number in tracker {0}: {1}; assign unique numbers' }
    'tracker.title.prefix' = @{ en = 'Title without prefix #{0}: {1}; run knowledge.ps1 -RenumberTasks' }
    'tracker.lastseq.type' = @{ en = 'extensions.lastSeq must be an integer: fix the value in the tracker' }
    'tracker.seq.beyond' = @{ en = 'Sequence number {0} beyond extensions.lastSeq ({1}): update lastSeq' }
    'tracker.schema.invalid' = @{ en = 'Tracker does not conform to schema v1: compare it with config/tracker.schema.json' }
    'tracker.identity.diverged' = @{ en = 'Tracker identity mismatch: check the dossier repository.json' }
    'tracker.date.invalid' = @{ en = 'Invalid tracker date: use the yyyy-MM-dd format' }
    'tracker.related.schema' = @{ en = 'Related tracker does not conform to schema v1: {0}' }
    'tracker.identity.unmanaged' = @{ en = 'Tracker of an unmanaged identity: activate the repository with secondbrain.ps1 -Setup or -AddRepo' }
    'tracker.id.duplicate' = @{ en = 'Duplicate tracker ID: {0}; make it unique' }
    'tracker.dependency.unmanaged' = @{ en = 'Dependency on an unmanaged identity: {0}; remove the dependency or activate that repository' }
    'tracker.enrichment.authorization' = @{ en = 'Applying an enrichment proposal needs the explicit authorization text of the person: pass -EnrichmentAuthorization' }
    'tracker.enrichment.none' = @{ en = 'Task {0} has no enrichment proposal' }
    'tracker.enrichment.state' = @{ en = 'The enrichment proposal of task {0} is already {1}; only a proposed one can be applied or rejected' }
    'tracker.enrichment.missing' = @{ en = 'Enrichment proposal file not found: {0}' }
    'tracker.enrichment.changed' = @{ en = 'The enrichment proposal {0} changed after it was recorded or is not a proposal for this task; nothing was applied' }
    'tracker.enrichment.invalid' =@{ en = 'Invalid enrichment pointer: it needs a SecondBrain-relative path to proposal.json, its SHA-256 and status proposed, applied or rejected' }
    'tracker.followup.missing' = @{ en = 'Follow-up source task not found: {0}; give the ID of an active or archived task of this tracker' }
    'tracker.dependency.missing' = @{ en = 'Tracker dependency missing or not verifiable: {0}; fix the ID or remove the dependency' }
    'tracker.dependency.cycle' = @{ en = 'Cycle in tracker dependencies: {0}; remove one of the dependencies' }
    'tracker.related.declaration' = @{ en = 'Invalid related tracker declaration: {0}' }
    'tracker.related.missing' = @{ en = 'Declared related tracker missing: {0}' }
    'tracker.related.identity' = @{ en = 'Related tracker identity mismatch' }
    'tracker.identity.area' = @{ en = 'Tracker identity not bound to exactly one Area: {0}' }
    'tracker.dossier.identity' = @{ en = 'Tracker dossier identity mismatch' }
    'tracker.declaration.invalid' = @{ en = 'Invalid tracker declaration: {0}' }
    'tracker.declared.missing' = @{ en = 'Declared tracker missing: {0}' }
    'tracker.greenfield.declaration.required' = @{ en = 'The greenfield dossier for {0} requires a declared schema 1 tracker' }
    'tracker.policy.unapproved' = @{ en = 'Tracker contract not approved: {0}' }
    'tracker.review.source' = @{ en = 'Tracker review of another identity or diverging source' }
    'tracker.review.tasks' = @{ en = 'Tracker review without task list' }
    'tracker.review.id' = @{ en = 'Tracker review ID missing or duplicate' }
    'tracker.review.field' = @{ en = 'Unrecognized tracker review field: {0}' }
    'tracker.review.reason' = @{ en = 'Tracker review reason is required' }
    'tracker.review.status' = @{ en = 'Invalid tracker review status' }
    'tracker.review.dependencies' = @{ en = 'Invalid tracker review dependencies' }
    'tracker.review.prerequisites' = @{ en = 'Invalid tracker review prerequisites' }
    'tracker.original.object' = @{ en = 'The original JSON tracker must be an object: fix the source file' }
    'tracker.collection.invalid' = @{ en = 'Invalid tracker collection: {0}; use tasks or a declared name' }
    'tracker.markdown.format' = @{ en = 'Unrecognized Markdown format at line {0}: explicit conversion required' }
    'tracker.original.format' = @{ en = 'Unsupported original tracker format: convert it to JSON or a Markdown table' }
    'tracker.id.collision' = @{ en = 'ID collision: explicit resolution required for {0}' }
    'tracker.review.unknown' = @{ en = 'Tracker review task does not exist: {0}' }
    'tracker.review.reconcile' = @{ en = 'Tracker review requires explicit dependency reconciliation: {0}' }
    'tracker.host.backuproot' = @{ en = 'Host configuration without backupRoot: {0}' }
    'tracker.write.foreign' = @{ en = 'Write refused: the tracker of ''{0}'' does not belong to the working repository ''{1}''' }
    'tracker.file.missing' = @{ en = 'Tracker file does not exist: {0}; check the path or the declaration in repository.json' }
    'tracker.identity.required' = @{ en = 'Identity or Path is required: give one of them' }
    'tracker.dossier.declaration' = @{ en = 'Dossier without tracker declaration: {0}; declare the tracker in repository.json' }
    'tracker.schema.version' = @{ en = 'Unsupported tracker schema (expected v1): set schemaVersion to 1' }
    'tracker.status.invalid' = @{ en = 'Invalid status: {0}. Allowed values: todo, in_progress, blocked, done, cancelled, unknown' }
    'tracker.task.notfound' = @{ en = 'Task not found in tracker: {0}. List tasks with knowledge.ps1 -Tasks' }
    'tracker.unnumbered' = @{ en = 'Unnumbered tracker ({0} tasks without seq): run knowledge.ps1 -RenumberTasks first' }
    'tracker.acceptance.required' = @{ en = 'At least one acceptance criterion is required: give -Acceptance' }
    'tracker.task.exists' = @{ en = 'Task ID already present: {0}; choose another ID or omit -TaskId' }
    'tracker.id.invalid' = @{ en = 'Invalid task ID: {0}. Use 3 to 80 characters (letters, digits, dot, hyphen, underscore) starting with a letter or digit, or omit -TaskId' }
    'tracker.title.invalid' = @{ en = 'Invalid title: it must contain at least one letter. Describe the task in a sentence' }
    'tracker.provenance.missing' = @{ en = 'Provenance does not exist: {0}. Give an existing dossier file (relative path)' }
    'tracker.archive.identity' = @{ en = 'Tracker archive of a diverging identity: check the dossier archive file' }
    'tracker.numbering.partial' = @{ en = 'Partial numbering ({0} of {1}): explicit reconciliation required' }
}

function Test-SBTrackerPolicy([string]$BrainRoot) {
    (Test-SBApproval $BrainRoot) -and (Read-SBText (Join-Path $BrainRoot 'direttive/workstation.template.md')).Contains('<!-- secondbrain:tracker-contract:1 -->')
}

# Sequential numbering: unique seq, consistent "#NNN - " title, extensions.lastSeq never below the maximum (numbers are never reused).
$script:SBTrackerSeqSeparator=' '+[char]0x2014+' '
function Format-SBTrackerSeqTitle([int]$Seq,[string]$Title) {
    '#'+$Seq.ToString('000')+$script:SBTrackerSeqSeparator+($Title -replace ('^#\d+'+[regex]::Escape($script:SBTrackerSeqSeparator)),'')
}
function Get-SBTrackerLastSeq($Document) {
    $last=0
    if($Document['extensions'] -is [Collections.IDictionary] -and $Document.extensions.ContainsKey('lastSeq')){$last=[int]$Document.extensions.lastSeq}
    foreach($task in $Document.tasks){if($task -is [Collections.IDictionary] -and $task.ContainsKey('seq') -and [int]$task.seq -gt $last){$last=[int]$task.seq}}
    $last
}
function Assert-SBTrackerSequence($Document) {
    $seen=@{}
    foreach($task in $Document.tasks){
        if($task -isnot [Collections.IDictionary] -or !$task.ContainsKey('seq')){continue}
        $seq=[int]$task.seq
        if($seen.ContainsKey($seq)){throw (New-SBError 'tracker.seq.duplicate' @($Document.repository,$seq))}
        $seen[$seq]=$true
        if(!([string]$task.title).StartsWith('#'+$seq.ToString('000')+$script:SBTrackerSeqSeparator)){throw (New-SBError 'tracker.title.prefix' @($seq.ToString('000'),$task.id))}
    }
    if($Document.extensions -is [Collections.IDictionary] -and $Document.extensions.ContainsKey('lastSeq')){
        $last=$Document.extensions.lastSeq
        if($last -isnot [int] -and $last -isnot [long]){throw (New-SBError 'tracker.lastseq.type')}
        foreach($seq in $seen.Keys){if($seq -gt $last){throw (New-SBError 'tracker.seq.beyond' @($seq,$last))}}
    }
}

function Test-SBTrackerData($Data, [string]$Identity, [string[]]$ManagedIdentities, [string]$SchemaPath, $RelatedTrackers=@{}, [hashtable]$Archives=@{}) {
    $json=ConvertTo-SBJson $Data
    if (!(Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) { throw (New-SBError 'tracker.schema.invalid') }
    if ($Data.repository -cne $Identity) { throw (New-SBError 'tracker.identity.diverged') }
    $date=[DateTimeOffset]::MinValue
    if (![DateTimeOffset]::TryParse($Data.updatedAt,[ref]$date)) { throw (New-SBError 'tracker.date.invalid') }
    $nodes=@{}
    foreach($document in @($Data)+@($RelatedTrackers.Values)) {
        if(!(Test-Json -Json (ConvertTo-SBJson $document) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)){
            $identityLabel=if($document.ContainsKey('repository')){$document.repository}else{'identita assente'}
            throw (New-SBError 'tracker.related.schema' @($identityLabel))
        }
        if ($document.repository -notin $ManagedIdentities) { throw (New-SBError 'tracker.identity.unmanaged') }
        $graph=if($Archives.ContainsKey($document.repository)){Join-SBTrackerArchive $document $Archives[$document.repository]}else{$document}
        Assert-SBTrackerSequence $graph
        foreach($task in $graph.tasks) {
            $key=$document.repository+'#'+$task.id
            if ($nodes.ContainsKey($key)) { throw (New-SBError 'tracker.id.duplicate' @($key)) }
            $nodes[$key]=@{task=$task;repository=$document.repository}
        }
    }
    $edges=@{}
    foreach($key in @($nodes.Keys)) {
        $edges[$key]=@()
        foreach($dependency in $nodes[$key].task['dependencies']) {
            $repository=if($dependency.ContainsKey('repository')){$dependency.repository}else{$nodes[$key].repository}
            if ($repository -notin $ManagedIdentities) { throw (New-SBError 'tracker.dependency.unmanaged' @($repository)) }
            $target=$repository+'#'+$dependency.id
            if (!$nodes.ContainsKey($target)) { throw (New-SBError 'tracker.dependency.missing' @($target)) }
            $edges[$key]+=$target
        }
    }
    $visited=@{};$active=@{}
    function Visit-SBTrackerNode([string]$Key) {
        if($active.ContainsKey($Key)){throw (New-SBError 'tracker.dependency.cycle' @($Key))}
        if($visited.ContainsKey($Key)){return}
        $active[$Key]=$true
        foreach($target in $edges[$Key]){Visit-SBTrackerNode $target}
        $active.Remove($Key);$visited[$Key]=$true
    }
    foreach($key in @($nodes.Keys)){Visit-SBTrackerNode $key}
    $true
}

function Read-SBTrackerArchive([string]$TrackerPath,[string]$Identity) {
    $path=Resolve-SBParaPath (Split-Path $TrackerPath) 'history/tracker-archive.json'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){
        return @{path=$path;hash='absent';changed=$false;data=@{schemaVersion=1;repository=$Identity;tasks=@()}}
    }
    $bytes=[IO.File]::ReadAllBytes($path)
    $data=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)|ConvertFrom-Json -AsHashtable -DateKind String
    if($data.schemaVersion -ne 1 -or $data.repository -cne $Identity -or $data.tasks -isnot [array] -or @($data.tasks|Where-Object {$_ -isnot [Collections.IDictionary] -or !$_['id'] -or $_['status'] -notin @('done','cancelled')}).Count){throw (New-SBError 'tracker.archive.identity')}
    @{path=$path;hash=(Get-SBHash $bytes);changed=$false;data=$data}
}

function ConvertTo-SBTrackerDependencies([string[]]$Values,$Data,$Archive) {
    # #591: "#<seq>" names a task of the same tracker by number, active or archived; it is stored by ID.
    # "repository#id" and bare IDs are kept as given and validated with the whole graph.
    $tasks=@(@($Data.tasks)+@($Archive.tasks)|Where-Object {$_ -is [Collections.IDictionary]})
    $result=@(@($Values)|ForEach-Object {$_ -split ';'}|ForEach-Object {$_.Trim()}|Where-Object {$_}|Select-Object -Unique|ForEach-Object {
        $value=$_
        if($value -match '^#(\d+)$'){
            $seq=[int]$Matches[1]
            $found=@($tasks|Where-Object {$_.ContainsKey('seq') -and [int]$_.seq -eq $seq})
            if($found.Count -ne 1){throw (New-SBError 'tracker.dependency.missing' @($value+' (no task with this number in the tracker or its archive; use the task ID or an existing #seq)'))}
            @{id=[string]$found[0].id}
        }else{
            $parts=$value -split '#',2
            if($parts.Count -eq 2){@{repository=$parts[0];id=$parts[1]}}else{@{id=$value}}
        }
    })
    ,$result
}

function Join-SBTrackerArchive($Data,$Archive) {
    $combined=@{}+$Data
    $combined.tasks=@($Data.tasks)+@($Archive.tasks)
    $combined
}

function Get-SBTrackerRelatedData([string]$BrainRoot,[string]$Identity,$Entities,[hashtable]$Archives) {
    # Read once without calling the resolver recursively; the validator visits the whole graph.
    $related=@{}
    foreach($other in $Entities|Where-Object {(Test-SBRepoDossier $_) -and $_.repository -ne $Identity}){
        $otherDir=Resolve-SBParaPath $BrainRoot $other.path
        $record=Read-SBJson (Join-Path $otherDir 'repository.json') @{}
        if(!$record.ContainsKey('tracker')){continue}
        $declaration=$record.tracker
        if($record.identity -cne $other.repository -or $declaration -isnot [Collections.IDictionary] -or $declaration.Count -ne 3 -or
           $declaration.location -ne 'dossier' -or $declaration.path -cne 'tracker.json' -or $declaration.schemaVersion -ne 1){throw (New-SBError 'tracker.related.declaration' @($other.repository))}
        $path=Resolve-SBParaPath $otherDir 'tracker.json'
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'tracker.related.missing' @($other.repository))}
        $data=Read-SBJson $path $null
        if($data.repository -cne $other.repository){throw (New-SBError 'tracker.related.identity')}
        if($null -ne $Archives){$Archives[$other.repository]=(Read-SBTrackerArchive $path $other.repository).data}
        $related[$other.repository]=$data
    }
    $related
}

function Resolve-SBTracker {
    param([string]$BrainRoot,[string]$Identity,[string]$CheckoutPath,[string[]]$AllowedOwners,$Entities=@(),[string]$DossierPath='',
        [switch]$AllowUndeclaredImportSource)
    if(!$Entities.Count){$Entities=@(Get-SBParaEntities $BrainRoot $AllowedOwners)}
    $areas=@($Entities|Where-Object {(Test-SBRepoDossier $_) -and $_.repository -eq $Identity})
    if(!$areas.Count -and $DossierPath -and (Test-SBRepositoryIdentity $Identity $AllowedOwners)){
        $areas=@(@{path=$DossierPath;repository=$Identity})
    }
    if($areas.Count -ne 1){throw (New-SBError 'tracker.identity.area' @($Identity))}
    $area=$areas[0];$dir=Resolve-SBParaPath $BrainRoot $area.path
    $metadata=Read-SBJson (Join-Path $dir 'repository.json') @{}
    if($metadata.ContainsKey('identity') -and $metadata.identity -ne $Identity){throw (New-SBError 'tracker.dossier.identity')}
    if($metadata.ContainsKey('tracker')) {
        $declaration=$metadata.tracker
        if($declaration -isnot [Collections.IDictionary] -or $declaration.Count -ne 3 -or
           $declaration.location -ne 'dossier' -or $declaration.path -cne 'tracker.json' -or $declaration.schemaVersion -ne 1){throw (New-SBError 'tracker.declaration.invalid' @($Identity))}
        $path=Resolve-SBParaPath $dir $declaration.path
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'tracker.declared.missing' @($path))}
        if(!(Test-SBTrackerPolicy $BrainRoot)){throw (New-SBError 'tracker.policy.unapproved' @($Identity))}
        $data=Read-SBJson $path $null
        if($data -is [Collections.IDictionary] -and $data.Contains('schemaVersion') -and $data.schemaVersion -ne 1){
            throw (New-SBError 'tracker.schema.version')
        }
        $archives=@{}
        $related=Get-SBTrackerRelatedData $BrainRoot $Identity $Entities $archives
        $archive=Read-SBTrackerArchive $path $Identity
        $archives[$Identity]=$archive.data
        $graph=Join-SBTrackerArchive $data $archive.data
        [void](Test-SBTrackerData $data $Identity @($Entities|Where-Object {Test-SBRepoDossier $_}|ForEach-Object repository) (Join-Path $PSScriptRoot '../config/tracker.schema.json') $related $archives)
        foreach($repo in @($related.Keys)){$related[$repo]=Join-SBTrackerArchive $related[$repo] $archives[$repo]}
        return @{source='dossier';path=$path;relativePath=$area.path+'/tracker.json';declared=$true;schemaVersion=1;data=$data;related=$related;graph=$graph;archive=$archive}
    }
    # Only explicit import may discover an original source for an undeclared greenfield tracker.
    if(!$AllowUndeclaredImportSource -and $metadata.ContainsKey('lifecycle') -and $metadata.lifecycle -ceq 'greenfield'){
        throw (New-SBError 'tracker.greenfield.declaration.required' @($Identity))
    }
    $path=if($CheckoutPath -and [IO.Path]::GetFullPath($CheckoutPath) -ne [IO.Path]::GetFullPath($dir)){
        $found=''
        foreach($name in @('tracker.json','tracker.md','tasks.json','legacy-tasks.json')){
            $candidate=Join-Path $CheckoutPath $name
            if(Test-Path -LiteralPath $candidate -PathType Leaf){$found=$candidate;break}
        }
        $found
    }else{''}
    $source='repository_undeclared'
    if(!$path -or !(Test-Path -LiteralPath $path -PathType Leaf)){$path=Join-Path $dir 'tracker.md';$source='dossier_undeclared'}
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return @{source='absent';path=$null;declared=$false;schemaVersion=$null}}
    Assert-SBPlainPath $path
    @{source=$source;path=$path;declared=$false;schemaVersion=$null}
}

function New-SBTrackerTask($Value,[string]$Identity,[string]$Collection,[string]$Reference,[string]$Hash,[string]$Pointer,[string]$Commit='') {
    $record=if($Value -is [Collections.IDictionary]){$Value}else{@{description=[string]$Value}}
    $title=''
    foreach($key in @('title','task','description','summary')){if($record.ContainsKey($key) -and $record[$key] -is [string] -and $record[$key].Trim()){$title=$record[$key];break}}
    if(!$title){$title='Record da verificare: '+$Collection}
    $id=if($record.ContainsKey('id') -and [string]$record.id){[string]$record.id}else{''}
    if(!$id -and $Value -is [string]){
        $ids=@([regex]::Matches($Value,'(?<![\w-])(?:[A-Z][A-Z0-9]*-)+\d+(?![\w-])')|ForEach-Object Value|Sort-Object -Unique)
        if($ids.Count -eq 1){$id=$ids[0]}
    }
    if(!$id){$id='MIG-'+(Get-SBTextHash ($Identity+"`n"+$Collection+"`n"+(ConvertTo-SBJson $Value))).Substring(0,12)}
    $original=if($record.ContainsKey('status')){$record.status}else{$null}
    $status=if($null -eq $original -and $Collection -in @('todos','todo_autonomous','todo_user_required')){'todo'}else{'unknown'}
    $states=@{planned='todo';pending='todo';open='todo';todo='todo';partial='in_progress';in_progress='in_progress';completed='done';done='done';superseded_removed='cancelled';cancelled='cancelled';external='blocked';blocked='blocked';blocked_by_execution_policy='blocked';pending_interactive_ui='blocked';verification_required_waiting_vm='blocked';waiting_lab_and_signing='blocked';waiting_user_certificate='blocked'}
    if($null -ne $original -and $states.ContainsKey([string]$original)){$status=$states[[string]$original]}
    $acceptance=@()
    foreach($key in @('acceptance_criteria','completion_criteria','closureCriteria','verify')){
        if(!$record.ContainsKey($key)){continue}
        foreach($item in @($record[$key])){
            if($null -ne $item){$acceptance+=if($item -is [string]){$item}else{(ConvertTo-SBJson $item).TrimEnd()}}
        }
    }
    $priority=if($record.ContainsKey('priority')){[string]$record.priority}elseif($record.ContainsKey('p')){[string]$record.p}else{$null}
    @{id=$id;title=$title;description=$(if($record.ContainsKey('description')){[string]$record.description}else{$title});status=$status;
      execution=$(switch($Collection){todo_autonomous{'autonomous'};todo_user_required{'user_required'};default{'unspecified'}});
      priority=$priority;dependencies=@();acceptance=$acceptance;evidence=@();
      provenance=@(@{reference=$Reference;sha256=$Hash;pointer=$Pointer;commit=$(if($Commit){$Commit}else{$null});originalId=$(if($record.ContainsKey('id')){[string]$record.id}else{$null});originalStatus=$original;originalCollection=$Collection});
      extensions=@{original=$Value}}
}

function Read-SBTrackerReview([string]$Path,[string]$Identity,[string]$SourceHash) {
    Assert-SBPlainPath ([IO.Path]::GetFullPath($Path))
    $review=Read-SBJson $Path $null
    if(!$review -or $review.schemaVersion -ne 1 -or $review.repository -cne $Identity -or $review.sourceSha256 -cne $SourceHash){throw (New-SBError 'tracker.review.source')}
    if($review.tasks -isnot [array]){throw (New-SBError 'tracker.review.tasks')}
    $ids=@{}
    foreach($item in $review.tasks){
        if($item -isnot [Collections.IDictionary] -or !$item.ContainsKey('id') -or !$item.id -or $ids.ContainsKey($item.id)){throw (New-SBError 'tracker.review.id')}
        $ids[$item.id]=$true
        foreach($key in $item.Keys){if($key -notin @('id','status','dependencies','prerequisites','reason')){throw (New-SBError 'tracker.review.field' @($key))}}
        if(!$item.ContainsKey('reason') -or $item.reason -isnot [string] -or !$item.reason.Trim()){throw (New-SBError 'tracker.review.reason')}
        if(!$item.ContainsKey('status') -or $item.status -notin @('todo','in_progress','blocked','done','cancelled')){throw (New-SBError 'tracker.review.status')}
        if($item.ContainsKey('dependencies') -and $item.dependencies -isnot [array]){throw (New-SBError 'tracker.review.dependencies')}
        if($item.ContainsKey('prerequisites') -and ($item.prerequisites -isnot [array] -or @($item.prerequisites|Where-Object {$_ -isnot [string] -or !$_.Trim()}).Count)){throw (New-SBError 'tracker.review.prerequisites')}
    }
    $review
}

# Schema-1 import: a dependency that names the tracker's own original repository becomes local once the
# tracker is realigned to a new identity. Mutates the given tasks; shared by ConvertTo-SBTracker and Portable.
function Remove-SBOriginDependencyRepository([object[]]$Tasks,[string]$OriginalRepository) {
    if(!$OriginalRepository){return}
    foreach($task in $Tasks){
        if($task -isnot [Collections.IDictionary] -or $task['dependencies'] -isnot [array]){continue}
        foreach($dependency in $task.dependencies){
            if($dependency -is [Collections.IDictionary] -and $dependency.Contains('repository') -and $dependency.repository -ceq $OriginalRepository){[void]$dependency.Remove('repository')}
        }
    }
}

function ConvertTo-SBTracker {
    param([string]$SourcePath,[string]$Identity,[string]$Reference=$SourcePath,[string]$Commit='',[string]$HistoryPath='',[string]$ReviewPath='')
    Assert-SBPlainPath $SourcePath
    $hash=Get-SBFileHash $SourcePath;$text=Read-SBText $SourcePath
    $tasks=[Collections.Generic.List[object]]::new();$history=@();$originalData=$null;$passThrough=$false;$carried=@{}
    if([IO.Path]::GetExtension($SourcePath) -eq '.json'){
        $originalData=Read-SBJson $SourcePath $null
        if($originalData -isnot [Collections.IDictionary]){throw (New-SBError 'tracker.original.object')}
        $passThrough=$originalData.Contains('schemaVersion') -and $originalData.schemaVersion -eq 1
    }
    if($passThrough){
        # Already a schema-1 tracker: ids, seq, status, evidence, provenance and history pass through
        # unchanged; only the repository is realigned (the original stays in extensions.original).
        if($originalData['tasks'] -isnot [array]){throw (New-SBError 'tracker.collection.invalid' @('tasks'))}
        $copy=ConvertTo-SBJson $originalData|ConvertFrom-Json -AsHashtable -DateKind String
        $originalRepository=if($copy.Contains('repository')){[string]$copy.repository}else{''}
        Remove-SBOriginDependencyRepository @($copy.tasks) $originalRepository
        foreach($task in @($copy.tasks)){$tasks.Add($task)}
        if($copy['history'] -is [array]){$history=@($copy.history)}
        if($copy['extensions'] -is [Collections.IDictionary]){$carried=$copy.extensions}
    } elseif([IO.Path]::GetExtension($SourcePath) -eq '.json'){
        foreach($collection in @('tasks','todos','current_tasks','next_tasks','remainingTasks','residuals','todo_autonomous','todo_user_required')){
            if(!$originalData.ContainsKey($collection)){continue}
            if($originalData[$collection] -isnot [array]){throw (New-SBError 'tracker.collection.invalid' @($collection))}
            $i=0
            foreach($value in $originalData[$collection]){$tasks.Add((New-SBTrackerTask $value $Identity $collection $Reference $hash ('/'+$collection+'/'+$i) $Commit));$i++}
        }
    } elseif([IO.Path]::GetExtension($SourcePath) -eq '.md') {
        $originalData=@{markdown=$text};$line=0;$inOpen=$false;$inResidual=$false;$fence=''
        foreach($row in $text -split '\r?\n'){
            $line++
            if($row -match '^\s{0,3}(`{3,}|~{3,})'){
                $mark=$Matches[1]
                if(!$fence){$fence=$mark}elseif($mark[0] -eq $fence[0] -and $mark.Length -ge $fence.Length){$fence=''}
                continue
            }
            if($fence){continue}
            if($row -match '^## '){$inOpen=$row -match '^## Attivit';$inResidual=$row -match '^## Residui'}
            $recognized=$false
            if($inOpen -and $row -match '^\| (?<id>SB-OPT-\d+) \| (?<state>[^|]+) \| (?<deps>[^|]+) \| (?<result>.+) \|$'){
                $m=@{}+$Matches;$value=@{id=$m.id;title=$m.result.Trim();status='pending';priority=($m.state.Trim() -split ' ')[0];description=$m.result.Trim();closureCriteria=$m.result.Trim();dependencies=@();originalRow=$row}
                if($m.state -match 'bloccato'){$value.status='blocked'}elseif($m.state -match 'parziale|in corso'){$value.status='PARTIAL'}
                $dependencyText=[regex]::Replace($m.deps,'SB-OPT-(\d+)\.\.(\d+)',[Text.RegularExpressions.MatchEvaluator]{param($match) (([int]$match.Groups[1].Value)..([int]$match.Groups[2].Value)|ForEach-Object {'SB-OPT-'+$_.ToString('00')}) -join ', '})
                # Conditions after a semicolon remain original text, not new prerequisites.
                if($dependencyText.TrimStart() -match '^SB-OPT-'){$value.dependencies=@([regex]::Matches(($dependencyText -split ';',2)[0],'SB-OPT-\d+')|ForEach-Object Value|Sort-Object -Unique)}
                $tasks.Add((New-SBTrackerTask $value $Identity 'markdown.open' $Reference $hash ('line:'+ $line) $Commit))
                $recognized=$true
            }
            if($inResidual -and $row -match '^- \[ \] (?<text>.+)$'){
                $value=@{description=$Matches.text;status=$(if($Matches.text -match 'rifiutat|blocked by policy'){'blocked'}else{'pending'})}
                $tasks.Add((New-SBTrackerTask $value $Identity 'markdown.residuals' $Reference $hash ('line:'+ $line) $Commit))
                $recognized=$true
            }
            $table=$row -match '^\s*\|'
            $header=$inOpen -and ($row -match '^\|\s*ID\s*\|[^|]*\|[^|]*\|[^|]*\|\s*$' -or $row -match '^\|(?:\s*:?-+:?\s*\|)+\s*$')
            $checkbox=$row -match '^\s*(?:[-*+]|\d+[.)])\s+\[[^\]]*\]'
            if(!$recognized -and (($table -and !$header) -or $checkbox)){
                throw (New-SBError 'tracker.markdown.format' @($line))
            }
        }
        if($HistoryPath){
            Assert-SBPlainPath $HistoryPath;$historyHash=Get-SBFileHash $HistoryPath;$historyText=Read-SBText $HistoryPath
            $history+=ConvertTo-SBTrackerHistoryRecord @{reference=$HistoryPath;sha256=$historyHash;description='Esiti storici espliciti usati per risolvere le dipendenze'}
            $line=0
            foreach($row in $historyText -split '\r?\n'){
                $line++
                if($row -match '^\| (?<id>SB-OPT-\d+) \| Completato[^|]* \| (?<result>.+) \|$'){
                    $v=@{id=$Matches.id;title=$Matches.result;status='completed'}
                    $task=New-SBTrackerTask $v $Identity 'markdown.completed' $HistoryPath $historyHash ('line:'+ $line) $Commit
                    $task.evidence=@(@{reference=$HistoryPath+'#chiusura-dei-task-del-lotto-1';outcome='passed'})
                    $tasks.Add($task)
                }
            }
        }
    } else {throw (New-SBError 'tracker.original.format')}
    $ids=@{};foreach($task in $tasks){if($ids.ContainsKey($task.id)){throw (New-SBError 'tracker.id.collision' @($task.id))};$ids[$task.id]=$true}
    foreach($task in $tasks){
        if($passThrough){break}
        $raw=$task.extensions.original
        if($raw -isnot [Collections.IDictionary]){continue}
        foreach($key in @('dependencies','dependsOn')){
            if(!$raw.ContainsKey($key)){continue}
            foreach($dependency in @($raw[$key])){
                if($dependency -is [string] -and $ids.ContainsKey($dependency)){$task.dependencies+=@{id=$dependency}}
                elseif($dependency -is [Collections.IDictionary] -and $dependency.ContainsKey('id')){$task.dependencies+=@{}+$dependency}
                else{
                    if(!$task.extensions.ContainsKey('unresolvedDependencies')){$task.extensions.unresolvedDependencies=@()}
                    $task.extensions.unresolvedDependencies+=,$dependency
                    $task.status='unknown'
                }
            }
        }
    }
    $review=$null
    if($ReviewPath){
        $review=Read-SBTrackerReview $ReviewPath $Identity $hash
        foreach($item in $review.tasks){
            $matches=@($tasks|Where-Object id -CEQ $item.id)
            if($matches.Count -ne 1){throw (New-SBError 'tracker.review.unknown' @($item.id))}
            $task=$matches[0]
            if($task.extensions.ContainsKey('unresolvedDependencies') -and !$item.ContainsKey('dependencies')){throw (New-SBError 'tracker.review.reconcile' @($item.id))}
            $task.status=$item.status
            if($item.ContainsKey('dependencies')){$task.dependencies=$item.dependencies}
            if($item.ContainsKey('prerequisites')){$task.extensions.prerequisites=$item.prerequisites}
            $task.extensions.review=@{reason=$item.reason;sourceSha256=$hash;reviewSha256=Get-SBFileHash $ReviewPath}
        }
    }
    $extensions=@{}+$carried;$extensions.original=$originalData;$extensions.source=@{reference=$Reference;sha256=$hash}
    $result=@{schemaVersion=1;repository=$Identity;updatedAt=(Get-SBNow).ToString('o');tasks=@($tasks);history=$history;extensions=$extensions}
    if($review){$result.extensions.review=@{sha256=Get-SBFileHash $ReviewPath;decisions=$review}}
    $result
}

function Convert-SBTrackerLocation($Data,[hashtable]$Mapping,[string]$BrainRoot,[string]$Dossier) {
    # Only typed references move. Imported original values and immutable candidates stay exact.
    $next=ConvertTo-SBJson $Data|ConvertFrom-Json -AsHashtable -DateKind String
    $newDossier=Convert-SBParaReferences $Dossier $Mapping $BrainRoot
    $oldDir=Resolve-SBParaPath $BrainRoot $Dossier
    $newDir=Resolve-SBParaPath $BrainRoot $newDossier
    $records=@($next.history)
    foreach($task in $next.tasks){$records+=@($task.provenance)+@($task.evidence)}
    if($next.extensions.ContainsKey('source') -and $next.extensions.source -is [Collections.IDictionary]){$records+=,$next.extensions.source}
    foreach($record in $records){
        if(!$record.ContainsKey('reference') -or $record.reference -isnot [string]){continue}
        $reference=$record.reference
        $relocated=Convert-SBParaReferences $reference $Mapping $BrainRoot
        if($relocated -cne $reference){$record.reference=$relocated;continue}
        if([IO.Path]::IsPathFullyQualified($reference) -or $reference -match '^(?:[a-z][a-z0-9+.-]*:|#|//|(?:01-projects|02-areas|03-resources|04-archives|docs|scripts|direttive|config)/)'){continue}
        $parts=$reference -split '(?=[#?])',2
        $resolved=[IO.Path]::GetFullPath((Join-Path $oldDir ([Uri]::UnescapeDataString($parts[0]))))
        if(!(Test-Path -LiteralPath $resolved)){continue}
        $resolved=Convert-SBParaReferences $resolved $Mapping $BrainRoot
        $record.reference=[Uri]::EscapeUriString([IO.Path]::GetRelativePath($newDir,$resolved).Replace('\','/'))
        if($parts.Count -gt 1){$record.reference+=$parts[1]}
    }
    $next
}

function Get-SBCuratedReferenceIssues([string]$BrainRoot,$Entities) {
    foreach($area in $Entities|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived}){
        $dir=Resolve-SBParaPath $BrainRoot $area.path
        foreach($name in @('context.md','memory.md','brief.md','tracker.md')){
            $path=Join-Path $dir $name
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
            Assert-SBPlainPath $path;$fence='';$lineNumber=0
            foreach($line in (Read-SBText $path) -split '\r?\n'){
                $lineNumber++
                if($line -match '^\s{0,3}(`{3,}|~{3,})'){
                    $mark=$Matches[1]
                    if(!$fence){$fence=$mark}elseif($mark[0] -eq $fence[0] -and $mark.Length -ge $fence.Length){$fence=''}
                    continue
                }
                if($fence){continue}
                # Stale paths in prose or inline code remain references; fenced blocks are excluded.
                foreach($match in [regex]::Matches($line,'(?<![\w:/\\.-])repos/[^/\s`<>]+/(?:context|memory|tracker)\.md')){
                    'Riferimento dossier obsoleto: '+$area.path+'/'+$name+':'+$lineNumber+': '+$match.Value
                }
                $prose=[regex]::Replace($line,'(?<ticks>`+)(?!`)(?:(?!\k<ticks>).)*?\k<ticks>','')
                foreach($match in [regex]::Matches($prose,'(?<!!)\[[^\]]*\]\((?<target><[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)')){
                    $target=$match.Groups['target'].Value.Trim('<','>')
                    if($target -match '^(?:[a-z][a-z0-9+.-]*:|#|//)'){continue}
                    $target=[Uri]::UnescapeDataString(($target -split '[#?]',2)[0])
                    if(!$target){continue}
                    $resolved=[IO.Path]::GetFullPath((Join-Path $dir $target))
                    Assert-SBPlainPath $resolved
                    if(!(Test-Path -LiteralPath $resolved)){'Target dossier mancante: '+$area.path+'/'+$name+':'+$lineNumber+': '+$target}
                }
            }
        }
    }
}

function Get-SBTrackerAuthorityIssues([string]$BrainRoot,$Entities) {
    foreach($project in $Entities|Where-Object {$_.kind -eq 'project' -and !(Test-SBRepoDossier $_) -and !$_.archived}){
        foreach($reference in $project.metadata.trackers){
            $area=@($Entities|Where-Object {(Test-SBRepoDossier $_) -and $_.id -eq $reference.area})[0]
            $dir=Resolve-SBParaPath $BrainRoot $area.path
            $record=Read-SBJson (Join-Path $dir 'repository.json') @{}
            if(!$record.ContainsKey('tracker')){continue}
            if(($reference.ContainsKey('repository') -and $reference.repository) -or $reference.path -cne 'tracker.json'){
                'Fonte tracker Progetto divergente: '+$project.id+'; Area='+$area.id+'; atteso tracker.json nel dossier'
            }
        }
    }
}

function Resolve-SBTrackerBackupRoot([string]$BrainRoot) {
    # Default backupRoot comes from the current host configuration (workstation.json, including migrated configurations);
    # without active configuration, use .runtime/backups/transactions. An existing invalid configuration is an error, not a fallback.
    $fallback=Join-Path $BrainRoot '.runtime/backups/transactions'
    $configPath=Get-SBHostConfigPath $BrainRoot
    if(!(Test-Path -LiteralPath $configPath -PathType Leaf)){return $fallback}
    $local=Read-SBJson $configPath $null
    if($local -is [Collections.IDictionary] -and $local.ContainsKey('migratedTo')){$local=Read-SBJson (Assert-SBCentralDataPath $BrainRoot $local.migratedTo) $null}
    if($local -isnot [Collections.IDictionary] -or !$local.ContainsKey('backupRoot') -or !$local.backupRoot){throw (New-SBError 'tracker.host.backuproot' @($configPath))}
    $value=[string]$local.backupRoot
    if(![IO.Path]::IsPathFullyQualified($value)){$value=Join-Path $BrainRoot $value}
    Assert-SBCentralDataPath $BrainRoot $value
}
# Resolve the writable tracker (by Path or dossier-declared identity) and enforce cooperative scope.
function Resolve-SBTrackerWriteTarget([string]$BrainRoot,[string]$Identity,[string]$Path,[string]$WorkingRepository) {
    if($WorkingRepository -and $Identity -and $Identity -cne $WorkingRepository){throw (New-SBError 'tracker.write.foreign' @($Identity,$WorkingRepository))}
    if(!$BrainRoot){
        if($Path){
            $p=[IO.Path]::GetFullPath($Path)
            while($p -and !(Test-Path (Join-Path $p 'direttive/approved.json'))){
                $parent=Split-Path $p -Parent
                if($parent -eq $p){break}
                $p=$parent
            }
            if(Test-Path (Join-Path $p 'direttive/approved.json')){$BrainRoot=$p}
        }
        if(!$BrainRoot){$BrainRoot=(Get-SBBrainRootPath)}
    }
    $BrainRoot=[IO.Path]::GetFullPath($BrainRoot)
    if($Path){
        $trackerPath=[IO.Path]::GetFullPath($Path)
        Assert-SBPlainPath $trackerPath
        if(!(Test-Path -LiteralPath $trackerPath -PathType Leaf)){throw (New-SBError 'tracker.file.missing' @($trackerPath))}
        $data=Read-SBJson $trackerPath $null
        if(!$Identity){$Identity=[string]$data.repository}
        if($WorkingRepository -and $Identity -cne $WorkingRepository){throw (New-SBError 'tracker.write.foreign' @($Identity,$WorkingRepository))}
    }else{
        if(!$Identity){throw (New-SBError 'tracker.identity.required')}
        if(!(Test-SBTrackerPolicy $BrainRoot)){throw (New-SBError 'tracker.policy.unapproved' @($Identity))}
        $entities=@(Get-SBParaEntities $BrainRoot @())
        $areas=@($entities|Where-Object {(Test-SBRepoDossier $_) -and $_.repository -eq $Identity})
        if($areas.Count -ne 1){throw (New-SBError 'tracker.identity.area' @($Identity))}
        $dir=Resolve-SBParaPath $BrainRoot $areas[0].path
        $metadata=Read-SBJson (Join-Path $dir 'repository.json') @{}
        if(!$metadata.ContainsKey('tracker')){throw (New-SBError 'tracker.dossier.declaration' @($Identity))}
        $declaration=$metadata.tracker
        if($declaration -isnot [Collections.IDictionary] -or $declaration.location -ne 'dossier' -or $declaration.path -cne 'tracker.json' -or $declaration.schemaVersion -ne 1){throw (New-SBError 'tracker.declaration.invalid' @($Identity))}
        $trackerPath=Resolve-SBParaPath $dir $declaration.path
        if(!(Test-Path -LiteralPath $trackerPath -PathType Leaf)){throw (New-SBError 'tracker.declared.missing' @($trackerPath))}
        $data=Read-SBJson $trackerPath $null
    }
    if($data.schemaVersion -ne 1){throw (New-SBError 'tracker.schema.version')}
    $next=ConvertTo-SBJson $data|ConvertFrom-Json -AsHashtable -DateKind String
    @{brainRoot=$BrainRoot;identity=$Identity;path=$trackerPath;hash=(Get-SBFileHash $trackerPath);data=$next}
}

# Validate the updated tracker across the entire graph, then write transactionally, with optional additional files in the same journal.
function Assert-SBTrackerWriteData([string]$BrainRoot,[string]$Identity,$Data,[string]$TrackerPath,$Archive) {
    $entities=@(Get-SBParaEntities $BrainRoot @())
    $managedIdentities=@($entities|Where-Object {Test-SBRepoDossier $_}|ForEach-Object repository)
    if($Identity -notin $managedIdentities){$managedIdentities+=,$Identity}
    $schemaPath=Join-Path $PSScriptRoot '../config/tracker.schema.json'
    $archives=@{}
    $related=Get-SBTrackerRelatedData $BrainRoot $Identity $entities $archives
    if(!$TrackerPath){
        $area=@($entities|Where-Object {(Test-SBRepoDossier $_) -and $_.repository -ceq $Identity})
        if($area.Count -eq 1){$TrackerPath=Resolve-SBParaPath $BrainRoot ($area[0].path+'/tracker.json')}
    }
    if(!$Archive -and $TrackerPath){$Archive=(Read-SBTrackerArchive $TrackerPath $Identity).data}
    if($Archive){$archives[$Identity]=$Archive}
    [void](Test-SBTrackerData $Data $Identity $managedIdentities $schemaPath $related $archives)
}
function Save-SBTrackerData($Target,$Data,[string]$BackupRoot,[switch]$WhatIf,[object[]]$ExtraOperations=@(),$Archive,$ArchiveForValidation,[object[]]$LedgerRecords=@()) {
    $Data.updatedAt=(Get-SBNow).ToString('o')
    if($Archive){$ArchiveForValidation=$Archive.data}
    Assert-SBTrackerWriteData $Target.brainRoot $Target.identity $Data $Target.path $ArchiveForValidation
    # Ledger records of this change go into history/task-runs.jsonl in the same transaction as the tracker.
    $ledger=Get-SBTaskLedgerOperation $Target.path $LedgerRecords
    if($ledger){$ExtraOperations=@($ExtraOperations)+@($ledger)}
    if($Archive){
        $terminal=@($Data.tasks|Where-Object {$_.status -in @('done','cancelled')})
        $Data.tasks=@($Data.tasks|Where-Object {$_.status -notin @('done','cancelled')})
        if($terminal.Count -or $Archive.changed){
            if(!$Data.extensions){$Data.extensions=@{}}
            $Data.extensions.lastSeq=[Math]::Max((Get-SBTrackerLastSeq $Data),(Get-SBTrackerLastSeq @{tasks=@($Archive.data.tasks)+$terminal}))
            $Archive.data.tasks+=@($terminal)
            $Archive.data.archivedAt=$Data.updatedAt
            $Archive.data.tasksCount=$Archive.data.tasks.Count
            $ExtraOperations+=@{path=$Archive.path;expected=$Archive.hash;bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $Archive.data))}
        }
        # A count kept in the tracker extensions follows the archive instead of going stale.
        if($Data.extensions -is [Collections.IDictionary] -and $Data.extensions['archive'] -is [Collections.IDictionary] -and $Data.extensions.archive.Contains('archivedTasksCount')){
            $Data.extensions.archive.archivedTasksCount=@($Archive.data.tasks).Count
        }
    }
    if($WhatIf){return @{applied=$false;path=$Target.path;data=$Data;extraOperations=$ExtraOperations}}
    if(!$BackupRoot){$BackupRoot=Resolve-SBTrackerBackupRoot $Target.brainRoot}
    [IO.Directory]::CreateDirectory($BackupRoot)|Out-Null
    $ops=@(@{path=$Target.path;expected=$Target.hash;bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $Data))})+@($ExtraOperations)
    foreach($op in @($ExtraOperations)){if($op.expected -eq 'absent'){[IO.Directory]::CreateDirectory((Split-Path $op.path))|Out-Null}}
    $manifest=Invoke-SBParaTransaction -Operations $ops -BackupRoot $BackupRoot -BrainRoot $Target.brainRoot
    @{applied=$true;manifest=$manifest;path=$Target.path;data=$Data}
}

function Resolve-SBTrackerTaskId([string]$TaskId,$Tasks) {
    # #593: "#<seq>" names a task of this tracker by number, active or archived, as -Task and -DependsOn do (#591); other values are IDs.
    if($TaskId -notmatch '^#(\d+)$'){return $TaskId}
    $seq=[int]$Matches[1]
    $bySeq=@(@($Tasks)|Where-Object {$_ -is [Collections.IDictionary] -and $_.ContainsKey('seq') -and [int]$_.seq -eq $seq})
    if($bySeq.Count -ne 1){throw (New-SBError 'tracker.task.notfound' @($TaskId+' (no task with this number in the tracker or its archive; use the task ID or an existing #seq)'))}
    [string]$bySeq[0].id
}

function Get-SBTrackerTaskForUpdate($Target,$Archive,[string]$TaskId) {
    $TaskId=Resolve-SBTrackerTaskId $TaskId (@($Target.data.tasks)+@($Archive.data.tasks))
    $matching=@($Target.data.tasks|Where-Object id -eq $TaskId)
    if(!$matching.Count){
        $matching=@($Archive.data.tasks|Where-Object id -eq $TaskId)
        if($matching.Count -eq 1){
            $Archive.data.tasks=@($Archive.data.tasks|Where-Object id -ne $TaskId)
            $Target.data.tasks+=,$matching[0]
            $Archive.changed=$true
        }
    }
    if($matching.Count -ne 1){throw (New-SBError 'tracker.task.notfound' @($TaskId))}
    $matching[0]
}

function Move-SBTerminalTrackerTasks([string]$BrainRoot,[string]$Identity,[switch]$Apply,[string]$BackupRoot) {
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity
    if([IO.Path]::GetRelativePath($target.brainRoot,$target.path).Replace('\','/').StartsWith('04-archives/')){throw (New-SBError 'tracker.archive.identity')}
    $archive=Read-SBTrackerArchive $target.path $target.identity
    $ids=@($target.data.tasks|Where-Object {$_.status -in @('done','cancelled')}|ForEach-Object id)
    if(!$ids.Count){return @{repository=$Identity;taskIds=$ids;applied=$false}}
    $saved=Save-SBTrackerData $target $target.data $BackupRoot -WhatIf:(!$Apply) -Archive $archive
    @{repository=$Identity;taskIds=$ids;applied=$saved.applied;manifest=$saved['manifest']}
}

# A timestamp is a reminder signal, not proof that a summary was reviewed.
function Get-SBClosureMemoryPending([string]$Dossier,$Tracker) {
    if(!$Tracker.extensions.ContainsKey('lastClosure')){return}
    $closure=$Tracker.extensions.lastClosure
    $closedAt=[DateTimeOffset]::MinValue
    if($closure -isnot [Collections.IDictionary] -or !$closure.ContainsKey('taskId') -or
       !$closure.taskId -or !$closure.ContainsKey('closedAt') -or
       ![DateTimeOffset]::TryParse([string]$closure.closedAt,[ref]$closedAt)){
        throw (New-SBError 'tracker.closure.invalid')
    }
    $memoryPath=Join-Path $Dossier 'memory.md'
    Assert-SBPlainPath $memoryPath
    $memoryUpdatedAt=if([IO.File]::Exists($memoryPath)){[DateTimeOffset][IO.File]::GetLastWriteTimeUtc($memoryPath)}else{$null}
    if(!$memoryUpdatedAt -or $closedAt -gt $memoryUpdatedAt){
        @{taskId=$closure.taskId;closedAt=$closure.closedAt;memoryUpdatedAt=$(if($memoryUpdatedAt){$memoryUpdatedAt.ToString('o')}else{$null})}
    }
}

function Set-SBTrackerTaskStatus {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [string]$Identity,
        [string]$Path,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Status,
        [string]$StateReason,
        $Evidence=@(),
        [string]$BackupRoot,
        [switch]$WhatIf,
        [string]$WorkingRepository,
        $Executor
    )
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity $Path $WorkingRepository
    if($Status -notin @('todo','in_progress','blocked','done','cancelled','unknown')){
        throw (New-SBError 'tracker.status.invalid' @($Status))
    }
    $next=$target.data
    $archive=Read-SBTrackerArchive $target.path $target.identity
    $targetTask=Get-SBTrackerTaskForUpdate $target $archive $TaskId
    $before=Get-SBTaskLedgerSnapshot $targetTask
    if($Status -eq 'done' -and $targetTask.status -ne 'done'){Set-SBTaskClosure $next $TaskId}
    $targetTask.status=$Status
    if($PSBoundParameters.ContainsKey('StateReason')){
        if(!$targetTask.ContainsKey('extensions') -or $null -eq $targetTask.extensions){$targetTask.extensions=@{}}
        if($StateReason){$targetTask.extensions.stateReason=$StateReason}
        else{[void]$targetTask.extensions.Remove('stateReason')}
    }
    if($Evidence -and @($Evidence).Count -gt 0){
        if(!$targetTask.ContainsKey('evidence') -or $null -eq $targetTask.evidence){$targetTask.evidence=@()}
        foreach($ev in @($Evidence)){$targetTask.evidence+=,(ConvertTo-SBTaskEvidence $ev)}
    }
    $record=New-SBTaskRunRecord -Task $targetTask -Before $before -Executor $Executor
    $saved=Save-SBTrackerData $target $next $BackupRoot -WhatIf:$WhatIf -Archive $archive -LedgerRecords @($record)
    $result=$saved+@{taskId=$TaskId;status=$Status}
    if($Status -eq 'done'){$result.closureAdvice=Get-SBClosureAdvice (Split-Path $target.path)}
    $result
}
# Closure signal and advice, shared by every writer that closes a task (status, update, memory cycle).
function Set-SBTaskClosure($Tracker,[string]$TaskId) {
    # Keep the latest closure on the tracker so archiving tasks preserves the signal.
    if($null -eq $Tracker.extensions){$Tracker.extensions=@{}}
    $Tracker.extensions.lastClosure=@{taskId=$TaskId;closedAt=(Get-SBNow).ToString('o')}
}
function Get-SBClosureAdvice([string]$Dossier) {
    $advice=@{code='tracker.closure.advice';message=(Get-SBMessage 'tracker.closure.advice');steps=@('memory','context','summary','sync','check');summaryOptions=@('memory','history','skip')}
    if($Dossier){$advice.dossier=$Dossier}
    $advice
}
function ConvertTo-SBTaskEvidence($Value) {
    # Evidence entries as the schema wants them: {reference, outcome, observedAt}; a "reference|outcome" string is accepted from the CLI.
    if($Value -is [Collections.IDictionary]){return $Value}
    $parts=([string]$Value) -split '\|',2
    $outcome=if($parts.Count -eq 2){$parts[1].Trim()}else{'unverified'}
    if(!$parts[0].Trim() -or $outcome -notin @('passed','failed','partial','unverified')){throw (New-SBError 'tracker.evidence.invalid')}
    @{reference=$parts[0].Trim();outcome=$outcome;observedAt=(Get-SBNow).ToString('o')}
}
function ConvertTo-SBTaskEvidenceList($Values) {
    # CLI evidence: ';' separates entries (pwsh -File delivers lists as one string). Every entry needs an explicit |outcome, so a reference holding ';' is refused instead of becoming garbled unverified entries; commas stay in the reference. Evidence is append-only: an empty list is refused.
    $entries=@(@($Values)|ForEach-Object{([string]$_) -split ';'}|ForEach-Object{$_.Trim()}|Where-Object{$_})
    if(!$entries.Count){throw (New-SBError 'tracker.evidence.invalid')}
    foreach($entry in $entries){if($entry -notmatch '^[^|]+\|[^|]+$'){throw (New-SBError 'tracker.evidence.invalid')}}
    @($entries|ForEach-Object{ConvertTo-SBTaskEvidence $_})
}
function ConvertTo-SBTaskDecisions($Value) {
    # Owner decisions recorded on a task (extensions.decisions): {questionId, question, answer, at, decidedBy}, from objects or a JSON text.
    $items=if($Value -is [string]){if($Value.Trim()){@($Value|ConvertFrom-Json -AsHashtable)}else{@()}}else{@($Value)}
    @($items|Where-Object {$_}|ForEach-Object {
        if($_ -isnot [Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$_['question']) -or [string]::IsNullOrWhiteSpace([string]$_['answer'])){throw (New-SBError 'tracker.decisions.invalid')}
        [ordered]@{questionId=[string]$_['questionId'];question=([string]$_.question).Trim();answer=([string]$_.answer).Trim();at=$(if($_['at']){[string]$_.at}else{(Get-SBNow).ToString('o')});decidedBy=$(if($_['decidedBy']){[string]$_.decidedBy}else{'owner'})}
    })
}

# #607: one deterministic readiness assessment for every creation path (CLI -NewTask, MCP task.new), every task update (CLI, MCP, the
# app's analysis) and the import report. Eight checks, each passed or with the missing elements as stable codes: objective (a meaningful
# title), scope (stream and description), inputs (provenance with hash), acceptance, dependencies (all known, none cancelled), tools
# (known required capabilities), authorization (autonomous, not awaiting anyone) and decisions (no open dec- decision on the task).
# Same task, tasks and decisions give the same result: no clock, no model. The result is stored on the task as extensions.readiness.
function Get-SBTaskReadiness($Task,$Tasks=$null,$Decisions=$null) {
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){if($o.Contains($n)){$o[$n]}else{$null}}elseif($null -ne $o -and $o.PSObject.Properties[$n]){$o.$n}else{$null}}
    $ext=& $field $Task 'extensions'
    $checks=[Collections.Generic.List[object]]::new()
    $add={param([string]$Name,[string[]]$Missing) $list=@($Missing|Where-Object {$_});$checks.Add([ordered]@{check=$Name;passed=($list.Count -eq 0);missing=$list})}
    $title=([string](& $field $Task 'title')) -replace ('^#\d+'+[regex]::Escape($script:SBTrackerSeqSeparator)),''
    & $add 'objective' $(if($title.Trim().Length -lt 8 -or $title -notmatch '\p{L}{3}' -or @($title.Trim() -split '\s+').Count -lt 2){'title'})
    $description=[string](& $field $Task 'description')
    & $add 'scope' @($(if(![string](& $field $ext 'stream')){'stream'}),$(if(!$description.Trim()){'description'}))
    $provenance=@(& $field $Task 'provenance'|Where-Object {$_ -and [string](& $field $_ 'reference') -and [string](& $field $_ 'sha256')})
    & $add 'inputs' $(if(!$provenance.Count){'provenance'})
    $acceptance=@(& $field $Task 'acceptance'|Where-Object {([string]$_).Trim()})
    & $add 'acceptance' $(if(!$acceptance.Count){'acceptance'})
    $depMissing=@()
    foreach($dependency in @(& $field $Task 'dependencies'|Where-Object {$_})){
        $depId=[string](& $field $dependency 'id')
        if($null -eq $Tasks){continue}
        $hit=@(@($Tasks)|Where-Object {$_ -and [string](& $field $_ 'id') -ceq $depId})
        if(!$hit.Count){$depMissing+='unknown:'+$depId}elseif([string](& $field $hit[0] 'status') -eq 'cancelled'){$depMissing+='cancelled:'+$depId}
    }
    & $add 'dependencies' $depMissing
    $known=@(Get-SBComputerUseRequiresValues)
    & $add 'tools' @(@(& $field $ext 'requires'|Where-Object {$_})|Where-Object {[string]$_ -cnotin $known}|ForEach-Object {'unknown:'+$_})
    $execution=[string](& $field $Task 'execution');$awaiting=[string](& $field $ext 'awaiting')
    & $add 'authorization' @($(if($execution -cne 'autonomous'){'execution:'+$(if($execution){$execution}else{'missing'})}),$(if($awaiting){'awaiting:'+$awaiting}))
    $taskId=[string](& $field $Task 'id');$open=@()
    $records=@(if($Decisions){@(& $field $Decisions 'decisions')|Where-Object {$_}})
    foreach($record in $records){
        $context=& $field $record 'context'
        if([string](& $field $record 'status') -eq 'open' -and $taskId -and [string](& $field $context 'taskId') -ceq $taskId){$open+=[string](& $field $record 'id')}
    }
    $linked=[string](& $field $ext 'decision')
    if($linked -and $linked -cnotin $open){
        $record=@($records|Where-Object {[string](& $field $_ 'id') -ceq $linked})
        if(!$record.Count -or [string](& $field $record[0] 'status') -eq 'open'){$open+=$linked}
    }
    & $add 'decisions' @($open|Sort-Object -Unique|ForEach-Object {'open:'+$_})
    $missing=@($checks|Where-Object {!$_.passed}|ForEach-Object {$_.check})
    [ordered]@{schemaVersion=1;ready=($missing.Count -eq 0);missing=$missing;checks=@($checks)}
}
function Set-SBTaskReadiness($Task,$Tasks,[string]$Dossier,[string]$Repository) {
    # Stores the assessment on a hashtable task (extensions.readiness); an unreadable decisions.json is reported, never ignored.
    if($Task.extensions -isnot [Collections.IDictionary]){$Task.extensions=@{}}
    $decisions=if($Dossier){(Read-SBDecisions $Dossier $Repository).data}else{$null}
    $Task.extensions.readiness=Get-SBTaskReadiness $Task $Tasks $decisions
    $Task.extensions.readiness
}

# Create a task with the next sequential number (never reused) and a "#NNN - " title.
# Requires an already numbered tracker: run Invoke-SBTrackerRenumber first for historical trackers.
function New-SBTrackerTaskEntry {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [string]$Identity,
        [string]$Path,
        [string]$WorkingRepository,
        [Parameter(Mandatory)][string]$Title,
        [string]$Id,
        [string]$Description,
        [string]$Priority='P2',
        [ValidateSet('autonomous','user_required','unspecified')][string]$Execution='autonomous',
        [string[]]$DependsOn=@(),
        [Parameter(Mandatory)][string[]]$Acceptance,
        [Parameter(Mandatory)][string]$ProvenanceReference,
        [string]$ProvenancePointer,
        [hashtable]$Extensions=@{},
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Requires=@(),
        [string]$FollowUpOf,
        [string]$BackupRoot,
        [switch]$WhatIf,
        $Executor
    )
    if($Priority -cnotin @('P0','P1','P2','P3','P4')){throw (New-SBError 'tracker.priority.invalid')}
    if($Id -and $Id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$'){throw (New-SBError 'tracker.id.invalid' @($Id))}
    if($Title -notmatch '\p{L}'){throw (New-SBError 'tracker.title.invalid')}
    $requiresList=ConvertTo-SBTaskRequires $Requires
    if($requiresList.Count){$Extensions=$Extensions+@{requires=@($requiresList)}}
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity $Path $WorkingRepository
    $next=$target.data
    $unnumbered=@($next.tasks|Where-Object {!$_.ContainsKey('seq')})
    if($unnumbered.Count){throw (New-SBError 'tracker.unnumbered' @($unnumbered.Count))}
    if(!@($Acceptance|Where-Object {$_ -and $_.Trim()}).Count){throw (New-SBError 'tracker.acceptance.required')}
    $archive=Read-SBTrackerArchive $target.path $target.identity
    $seq=(Get-SBTrackerLastSeq (Join-SBTrackerArchive $next $archive.data))+1
    if(!$Id){$Id='TASK-'+$seq.ToString('000')}
    if(@(@($next.tasks)+@($archive.data.tasks)|Where-Object {$_.id -ieq $Id}).Count){throw (New-SBError 'tracker.task.exists' @($Id))}
    if($FollowUpOf){
        # #611: a follow-up links its source task (active or archived) and inherits its stream unless one is given.
        $origin=@(@($next.tasks)+@($archive.data.tasks)|Where-Object {$_.id -ieq $FollowUpOf})
        if(!$origin.Count){throw (New-SBError 'tracker.followup.missing' @($FollowUpOf))}
        $Extensions=@{}+$Extensions;$Extensions.followUpOf=[string]$origin[0].id
        if(!$Extensions.ContainsKey('stream') -and $origin[0].extensions -is [Collections.IDictionary] -and $origin[0].extensions['stream']){$Extensions.stream=[string]$origin[0].extensions['stream']}
    }
    # Provenance is a real file: dossier-relative or absolute reference; compute its hash here.
    $dossierDir=Split-Path $target.path
    $sourcePath=if([IO.Path]::IsPathFullyQualified($ProvenanceReference)){$ProvenanceReference}else{Join-Path $dossierDir (($ProvenanceReference -split '#',2)[0])}
    if(!(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw (New-SBError 'tracker.provenance.missing' @($ProvenanceReference))}
    Assert-SBPlainPath $sourcePath
    $dependencies=ConvertTo-SBTrackerDependencies $DependsOn $next $archive.data
    $task=@{
        id=$Id;seq=$seq;title=(Format-SBTrackerSeqTitle $seq $Title);status='todo';execution=$Execution;priority=$Priority
        dependencies=$dependencies;acceptance=@($Acceptance);evidence=@()
        provenance=@(@{reference=$ProvenanceReference;sha256=(Get-SBFileHash $sourcePath);pointer=$(if($ProvenancePointer){$ProvenancePointer}else{$Title})})
        extensions=$Extensions
    }
    if($Description){$task.description=$Description}
    [void](Set-SBTaskReadiness $task (@($next.tasks)+@($archive.data.tasks)) $dossierDir $target.identity)
    $next.tasks+=,$task
    if($null -eq $next.extensions){$next.extensions=@{}}
    $next.extensions.lastSeq=$seq
    $saved=Save-SBTrackerData $target $next $BackupRoot -WhatIf:$WhatIf -LedgerRecords @(New-SBTaskRunRecord -Task $task -Executor $Executor -Created)
    $saved+@{taskId=$Id;seq=$seq;title=$task.title}
}

# Retrospective chronological numbering: archive and active tracker; date from the ID (yyyyMMdd) or inherited from the previous task.
# Stable ordering; preserve originals by hash in history/tracker-seq/<sha256>/ within the same transaction. Without -Apply, preview only.
function Invoke-SBTrackerRenumber {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [string]$Identity,
        [string]$Path,
        [string]$WorkingRepository,
        [string]$ArchivePath,
        [string]$BackupRoot,
        [switch]$Apply
    )
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity $Path $WorkingRepository
    $next=$target.data
    $dossierDir=Split-Path $target.path
    if(!$ArchivePath){$ArchivePath=Join-Path $dossierDir 'history/tracker-archive.json'}
    $archive=$null;$archiveHash='absent'
    if(Test-Path -LiteralPath $ArchivePath -PathType Leaf){
        Assert-SBPlainPath $ArchivePath
        $archiveHash=Get-SBFileHash $ArchivePath
        $archive=ConvertTo-SBJson (Read-SBJson $ArchivePath $null)|ConvertFrom-Json -AsHashtable -DateKind String
        if($archive -isnot [Collections.IDictionary] -or $archive.repository -cne $target.identity){throw (New-SBError 'tracker.archive.identity')}
    }
    $items=@()
    if($archive){foreach($t in $archive.tasks){$items+=,@{task=$t;source='archive'}}}
    foreach($t in $next.tasks){$items+=,@{task=$t;source='tracker'}}
    $numbered=@($items|Where-Object {$_.task.ContainsKey('seq')})
    if($items.Count -and $numbered.Count -eq $items.Count){return @{applied=$false;changed=$false;reason='Tracker gia numerato';code='tracker.reason.numbered';message=(Get-SBMessage 'tracker.reason.numbered');count=$items.Count;lastSeq=(Get-SBTrackerLastSeq $next)}}
    if($numbered.Count){throw (New-SBError 'tracker.numbering.partial' @($numbered.Count,$items.Count))}
    $current='00000000';$index=0
    foreach($item in $items){
        $match=[regex]::Match([string]$item.task.id,'(?<!\d)(20\d{6})(?!\d)')
        if($match.Success){$current=$match.Groups[1].Value}
        $item.date=$current;$item.index=$index;$index++
    }
    $ordered=@($items|Sort-Object @{Expression={$_.date}},@{Expression={$_.index}})
    $mapping=@();$seq=0
    foreach($item in $ordered){
        $seq++
        $item.task.seq=$seq
        $item.task.title=Format-SBTrackerSeqTitle $seq ([string]$item.task.title)
        $mapping+=,@{seq=$seq;id=$item.task.id;source=$item.source}
    }
    if($null -eq $next.extensions){$next.extensions=@{}}
    $next.extensions.lastSeq=$seq
    $originalRel='history/tracker-seq/'+$target.hash.ToLowerInvariant()
    $originalRoot=Join-Path $dossierDir $originalRel
    $extra=@(@{path=(Join-Path $originalRoot 'tracker.json');expected='absent';bytes=[IO.File]::ReadAllBytes($target.path)})
    if($archive){
        $extra+=@{path=(Join-Path $originalRoot 'tracker-archive.json');expected='absent';bytes=[IO.File]::ReadAllBytes($ArchivePath)}
        $extra+=@{path=[IO.Path]::GetFullPath($ArchivePath);expected=$archiveHash;bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $archive))}
    }
    $next.history+=,(ConvertTo-SBTrackerHistoryRecord @{reference=$originalRel+'/tracker.json';sha256=$target.hash;description="Retroactive numbering: $seq tasks (archive and active) in chronological order; originals kept by hash."})
    $saved=Save-SBTrackerData $target $next $BackupRoot -WhatIf:(!$Apply) -ExtraOperations $extra -ArchiveForValidation $archive
    $saved.Remove('data')
    $saved+@{changed=$true;count=$seq;lastSeq=$seq;originals=$originalRel;mapping=$mapping}
}

function ConvertTo-SBTrackerHistoryRecord([System.Collections.IDictionary]$Record) {
    $next = @{} + $Record
    if ($next.ContainsKey('code')) { return $next }
    $description = [string]$next.description
    $next.code = 'tracker.history.note'; $next.messageArgs = @()
    if ($description -ceq 'Esiti storici espliciti usati per risolvere le dipendenze') {
        $next.code = 'tracker.history.dependencies'; $next.messageArgs = @()
    } elseif ($description -cmatch '^(?:Numerazione retroattiva: (\d+) task \(archivio e attivi\) in ordine cronologico; originali conservati per hash|Retroactive numbering: (\d+) tasks \(archive and active\) in chronological order; originals kept by hash)\.$') {
        $next.code = 'tracker.history.numbered'; $next.messageArgs = @([int]$(if($Matches[1]){$Matches[1]}else{$Matches[2]}))
    }
    $next
}

function Get-SBTrackerHistoryMessages($Data) {
    # Derived view only: persisted descriptions and free notes remain unchanged.
    $records = @()
    if ($Data.ContainsKey('history')) { $records += @($Data.history) }
    if ($Data.ContainsKey('description')) {
        $metadata = @{}
        foreach ($key in @('description','code','messageArgs','reference','sha256','archivedAt')) {
            if ($Data.ContainsKey($key)) { $metadata[$key] = $Data[$key] }
        }
        $records += ,$metadata
    }
    foreach ($record in $records) {
        $view = ConvertTo-SBTrackerHistoryRecord $record
        $arguments = @()
        if ($view.ContainsKey('messageArgs')) { $arguments = @($view.messageArgs) }
        if ($view.code -eq 'tracker.history.note') { $arguments = @($view.description) }
        $view.message = Get-SBMessage $view.code $arguments
        $view
    }
}

function Invoke-SBTrackerHistoryMigration {
    [CmdletBinding()]
    param([string]$BrainRoot, [string]$Identity, [string]$Path, [string]$WorkingRepository,
        [string]$BackupRoot, [switch]$Apply)
    $target = Resolve-SBTrackerWriteTarget $BrainRoot $Identity $Path $WorkingRepository
    Assert-SBTrackerWriteData $target.brainRoot $target.identity $target.data $target.path
    $dir = Split-Path $target.path
    $archivePath = Join-Path $dir 'history/tracker-archive.json'
    $inputs = @(@{path=$target.path;data=$target.data;hash=$target.hash;name='tracker.json'})
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        Assert-SBPlainPath $archivePath
        $bytes = [IO.File]::ReadAllBytes($archivePath)
        $archive = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -DateKind String
        if ($archive.repository -cne $target.identity -or $archive.schemaVersion -ne 1 -or !$archive.ContainsKey('tasks')) { throw (New-SBError 'tracker.archive.identity') }
        $inputs += @{path=$archivePath;data=$archive;hash=(Get-SBHash $bytes);name='tracker-archive.json'}
    }
    $operations = @(); $changes = @(); $originals = @()
    foreach ($inputFile in $inputs) {
        $bytes = [IO.File]::ReadAllBytes($inputFile.path)
        if ((Get-SBHash $bytes) -cne $inputFile.hash -or (ConvertTo-SBJson (Read-SBJson $inputFile.path $null)) -cne (ConvertTo-SBJson $inputFile.data)) {
            throw (New-SBError 'tracker.history.snapshot' @($inputFile.name))
        }
        $before = ConvertTo-SBJson $inputFile.data
        $next = ConvertTo-SBJson $inputFile.data | ConvertFrom-Json -AsHashtable -DateKind String
        if ($next.ContainsKey('history')) { $next.history = @($next.history | ForEach-Object { ConvertTo-SBTrackerHistoryRecord $_ }) }
        if ($next.ContainsKey('description')) { $next = ConvertTo-SBTrackerHistoryRecord $next }
        if ((ConvertTo-SBJson $next) -ceq $before) { continue }
        $snapshot = Join-Path $dir ('history/tracker-messages/' + $inputFile.hash.ToLowerInvariant() + '/' + $inputFile.name)
        if (Test-Path -LiteralPath $snapshot) {
            if ((Get-SBFileHash $snapshot) -cne $inputFile.hash) { throw (New-SBError 'tracker.history.snapshot' @($snapshot)) }
        } else { $operations += @{path=$snapshot;expected='absent';bytes=$bytes} }
        $originals += @{path=[IO.Path]::GetRelativePath($dir,$snapshot).Replace('\','/');sha256=$inputFile.hash}
        $changes += $inputFile.name
        if ($inputFile.name -eq 'tracker.json') { $target.data = $next }
        else { $operations += @{path=$inputFile.path;expected=$inputFile.hash;bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $next))} }
    }
    if (!$changes.Count) { return @{applied=$false;changed=$false;files=@();originals=@()} }
    $saved = Save-SBTrackerData $target $target.data $BackupRoot -WhatIf:(!$Apply) -ExtraOperations $operations
    $saved.Remove('data')
    $saved + @{changed=$true;files=$changes;originals=$originals}
}

# Capabilities a task may require; the runner leaves such tasks to an attended session (extensions.requires).
# The vocabulary lives in SecondBrain.ComputerUse.psm1; this wrapper keeps the public name used by callers.
function Get-SBTaskRequiresValues { Get-SBComputerUseRequiresValues }
function ConvertTo-SBTaskRequires([string[]]$Value) {
    # Lists arrive as one ';'-separated string with pwsh -File; unknown values are rejected, duplicates dropped, empty clears.
    $items=@($Value|ForEach-Object {$_ -split ';'}|ForEach-Object {$_.Trim()}|Where-Object {$_}|Select-Object -Unique)
    foreach($item in $items){if($item -cnotin (Get-SBComputerUseRequiresValues)){throw (New-SBError 'tracker.requires.invalid' @($item,((Get-SBComputerUseRequiresValues) -join ', ')))}}
    ,$items
}
function Update-SBTrackerTask {
    [CmdletBinding()]
    param(
        [string]$BrainRoot,
        [string]$Identity,
        [string]$Path,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Status,
        [string]$StateReason,
        [string]$Priority,
        [string]$Execution,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$DependsOn,
        [AllowEmptyString()][string]$Stream,
        [AllowEmptyString()][string]$Awaiting,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Requires,
        $Evidence=@(),
        $EvidenceCorrection,
        [string]$Description,
        [string[]]$Acceptance,
        $Decisions,
        [AllowEmptyString()][string]$Decision,
        $Enrichment,
        [string]$BackupRoot,
        [switch]$WhatIf,
        [string]$WorkingRepository,
        $Executor
    )
    $fields=@{}
    foreach($field in (Get-SBTrackerUpdateFields)){if($PSBoundParameters.ContainsKey($field)){$fields[$field]=$PSBoundParameters[$field]}}
    Assert-SBTrackerUpdateFields $fields
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity $Path $WorkingRepository
    $archive=Read-SBTrackerArchive $target.path $target.identity
    $edit=Edit-SBTrackerTaskFields $target $archive $TaskId $fields $Executor
    $saved=Save-SBTrackerData $target $target.data $BackupRoot -WhatIf:$WhatIf -Archive $archive -LedgerRecords @($edit.record)
    $result=$saved+@{taskId=$edit.taskId;status=$edit.status}
    if($edit.closing){$result.closureAdvice=Get-SBClosureAdvice (Split-Path $target.path)}
    $result
}
function Get-SBTrackerUpdateFields {@('Status','StateReason','Priority','Execution','DependsOn','Stream','Awaiting','Requires','Evidence','EvidenceCorrection','Description','Acceptance','Decisions','Decision','Enrichment')}
function ConvertTo-SBEvidenceCorrection($Value) {
    # #669: the audited correction of one task's evidence: a mandatory reason and the replacement list (empty removes every entry).
    # Entries are "reference|outcome" strings or {reference, outcome[, observedAt]}. The replaced entries are kept in extensions.evidenceCorrections.
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){$o[$n]}elseif($null -ne $o -and $o.PSObject.Properties[$n]){$o.$n}else{$null}}
    $reason=([string](& $field $Value 'Reason')).Trim()
    $items=@(@(& $field $Value 'Evidence')|Where-Object {$null -ne $_ -and ($_ -isnot [string] -or $_.Trim())})
    if(!$reason -or $reason.Length -gt 1024 -or $items.Count -gt 100){throw (New-SBError 'tracker.evidence.correction.invalid')}
    foreach($item in $items){
        if($item -is [string] -and $item -notmatch '^[^|]+\|[^|]+$'){throw (New-SBError 'tracker.evidence.invalid')}
    }
    @{reason=$reason;evidence=@($items|ForEach-Object {ConvertTo-SBTaskEvidence $_})}
}
function ConvertTo-SBTaskEnrichment($Value) {
    # #608: pointer to a light-model proposal kept in a work folder: SecondBrain-relative path, SHA-256 of proposal.json, status and time.
    # Only the pointer reaches the tracker; the proposal is applied, if ever, through a reviewed update.
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){$o[$n]}elseif($null -ne $o -and $o.PSObject.Properties[$n]){$o.$n}else{$null}}
    $path=([string](& $field $Value 'path')).Replace('\','/')
    $hash=[string](& $field $Value 'sha256');$status=[string](& $field $Value 'status');$at=[string](& $field $Value 'at')
    if(!$path -or [IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)' -or $path -notmatch '/proposal\.json$' -or $hash -notmatch '^[A-Fa-f0-9]{64}$' -or $status -cnotin @('proposed','applied','rejected')){
        throw (New-SBError 'tracker.enrichment.invalid')
    }
    [ordered]@{path=$path;sha256=$hash.ToUpperInvariant();status=$status;at=$at}
}
function New-SBEnrichmentUpdate {
    # #645: the reviewed step after a proposal (#608). Apply returns the update fields of exactly the proposal's own fields (description,
    # acceptance, stream, requires) plus the pointer set to applied, and the proposal file must still have the SHA-256 recorded in the pointer
    # (a changed proposal is refused); reject returns only the pointer set to rejected and does not depend on the file.
    param([Parameter(Mandatory)][string]$BrainRoot,[Parameter(Mandatory)]$Task,[Parameter(Mandatory)][ValidateSet('apply','reject')][string]$Action)
    $taskId=[string]$Task['id']
    $raw=if($Task['extensions'] -is [Collections.IDictionary]){$Task['extensions']['enrichment']}else{$null}
    if(!$raw){throw (New-SBError 'tracker.enrichment.none' @($taskId))}
    $pointer=ConvertTo-SBTaskEnrichment $raw
    if($pointer.status -cne 'proposed'){throw (New-SBError 'tracker.enrichment.state' @($taskId,$pointer.status))}
    $update=[ordered]@{}
    if($Action -eq 'apply'){
        # Reject never reads the file: a missing or edited proposal can still be rejected.
        $file=[IO.Path]::GetFullPath((Join-Path $BrainRoot $pointer.path))
        if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw (New-SBError 'tracker.enrichment.missing' @($pointer.path))}
        if((Get-SBFileHash $file) -ine $pointer.sha256){throw (New-SBError 'tracker.enrichment.changed' @($pointer.path))}
        $record=Read-SBJson $file $null
        if($null -eq $record -or [string]$record['kind'] -cne 'task-enrichment' -or [string]$record['taskId'] -cne $taskId -or $record['proposal'] -isnot [Collections.IDictionary]){throw (New-SBError 'tracker.enrichment.changed' @($pointer.path))}
        $map=[ordered]@{description='Description';acceptance='Acceptance';stream='Stream';requires='Requires'}
        foreach($name in $map.Keys){
            $value=$record['proposal'][$name]
            if($null -eq $value -or ($value -is [string] -and !$value.Trim()) -or ($value -is [array] -and !@($value).Count)){continue}
            $update[$map[$name]]=if($value -is [array]){@($value|ForEach-Object {[string]$_})}else{[string]$value}
        }
    }
    $update['Enrichment']=[ordered]@{path=$pointer.path;sha256=$pointer.sha256;status=$(if($Action -eq 'apply'){'applied'}else{'rejected'});at=(Get-SBNow).ToString('o')}
    $update
}
function Assert-SBTrackerUpdateFields([hashtable]$Fields) {
    # Field checks shared by the single update and the batch (#595), before any tracker is read.
    if(!@((Get-SBTrackerUpdateFields)|Where-Object {$Fields.ContainsKey($_)}).Count){throw (New-SBError 'tracker.update.empty')}
    if($Fields.ContainsKey('Status') -and $Fields.Status -notin @('todo','in_progress','blocked','done','cancelled','unknown')){throw (New-SBError 'tracker.status.invalid' @($Fields.Status))}
    if($Fields.ContainsKey('Priority') -and $Fields.Priority -cnotin @('P0','P1','P2','P3','P4')){throw (New-SBError 'tracker.priority.invalid')}
    if($Fields.ContainsKey('Execution') -and $Fields.Execution -cnotin @('autonomous','user_required','unspecified')){throw (New-SBError 'tracker.execution.invalid')}
    if($Fields.ContainsKey('Requires')){[void](ConvertTo-SBTaskRequires $Fields.Requires)}
    if($Fields.ContainsKey('Enrichment')){[void](ConvertTo-SBTaskEnrichment $Fields.Enrichment)}
    if($Fields.ContainsKey('EvidenceCorrection')){
        [void](ConvertTo-SBEvidenceCorrection $Fields.EvidenceCorrection)
        if($Fields.ContainsKey('Evidence')){throw (New-SBError 'tracker.evidence.correction.invalid')}
    }
}
function Edit-SBTrackerTaskFields($Target,$Archive,[string]$TaskId,[hashtable]$Fields,$Executor) {
    # Applies one update to the in-memory tracker and archive; the caller saves (one task: Update-SBTrackerTask; several: Invoke-SBTrackerTaskBatch).
    Assert-SBTrackerUpdateFields $Fields
    $next=$Target.data
    $task=Get-SBTrackerTaskForUpdate $Target $Archive $TaskId
    $TaskId=[string]$task.id
    $before=Get-SBTaskLedgerSnapshot $task
    $wasDone=$task.status -eq 'done'
    if(!$task.ContainsKey('extensions') -or $null -eq $task.extensions){$task.extensions=@{}}
    if($Fields.ContainsKey('Description')){$text=[string]$Fields.Description;if($text.Trim()){$task.description=$text.Trim()}else{[void]$task.Remove('description')}}
    if($Fields.ContainsKey('Acceptance')){
        $criteria=@(@($Fields.Acceptance)|ForEach-Object {[string]$_ -split ';'}|ForEach-Object {$_.Trim()}|Where-Object {$_})
        if(!$criteria.Count){throw (New-SBError 'tracker.acceptance.required')}
        $task.acceptance=$criteria
    }
    if($Fields.ContainsKey('Decisions')){
        $added=@(ConvertTo-SBTaskDecisions $Fields.Decisions)
        if($added.Count){$task.extensions.decisions=@(@($task.extensions['decisions']|Where-Object {$_})+$added)}
    }
    foreach($field in @('Status','Priority','Execution')){
        if($Fields.ContainsKey($field)){$task[$field.ToLowerInvariant()]=[string]$Fields[$field]}
    }
    foreach($field in @('StateReason','Stream','Awaiting')){
        if($Fields.ContainsKey($field)){
            $key=switch($field){'StateReason'{'stateReason'}'Stream'{'stream'}default{'awaiting'}}
            $value=([string]$Fields[$field]).Trim()
            if($value){$task.extensions[$key]=$value}else{[void]$task.extensions.Remove($key)}
        }
    }
    if($Fields.ContainsKey('Requires')){
        $requiresList=ConvertTo-SBTaskRequires @($Fields.Requires)
        if($requiresList.Count){$task.extensions.requires=@($requiresList)}else{[void]$task.extensions.Remove('requires')}
    }
    if($Fields.ContainsKey('Decision')){
        # #588: a task waiting on the user points at an open decision of its own dossier (awaiting=owner-consent); empty clears the link.
        $decisionId=([string]$Fields.Decision).Trim()
        if($decisionId){
            $awaitingNow=if($task.extensions.Contains('awaiting')){[string]$task.extensions.awaiting}else{''}
            Assert-SBDecisionLink (Split-Path $Target.path) $Target.identity $decisionId $TaskId $awaitingNow
            $task.extensions.decision=$decisionId
        }else{[void]$task.extensions.Remove('decision')}
    }
    if($Fields.ContainsKey('DependsOn')){
        $task.dependencies=ConvertTo-SBTrackerDependencies @($Fields.DependsOn) $next $Archive.data
    }
    if($Fields.ContainsKey('Enrichment')){$task.extensions.enrichment=ConvertTo-SBTaskEnrichment $Fields.Enrichment}
    if($Fields.ContainsKey('Evidence') -and $Fields.Evidence){if(!$task.ContainsKey('evidence')){$task.evidence=@()};$task.evidence+=@(@($Fields.Evidence)|ForEach-Object {ConvertTo-SBTaskEvidence $_})}
    $corrected=$null
    if($Fields.ContainsKey('EvidenceCorrection')){
        $correction=ConvertTo-SBEvidenceCorrection $Fields.EvidenceCorrection
        $previous=@(@($task['evidence'])|Where-Object {$null -ne $_})
        $audit=[ordered]@{at=(Get-SBNow).ToString('o');reason=$correction.reason;previousCount=$previous.Count;replacementCount=@($correction.evidence).Count;previous=@($previous)}
        $task.extensions.evidenceCorrections=@(@($task.extensions['evidenceCorrections']|Where-Object {$_})+@($audit))
        $task.evidence=@($correction.evidence)
        $corrected=$correction.reason
    }
    # #607: every update of an open task (CLI, MCP, batch, the app's analysis) re-runs the same readiness assessment.
    if([string]$task.status -cnotin @('done','cancelled')){[void](Set-SBTaskReadiness $task (@($next.tasks)+@($Archive.data.tasks)) (Split-Path $Target.path) $Target.identity)}
    $closing=$Fields.ContainsKey('Status') -and $Fields.Status -eq 'done'
    if($closing -and !$wasDone){Set-SBTaskClosure $next $TaskId}
    $record=New-SBTaskRunRecord -Task $task -Before $before -Executor $Executor
    # #669: a correction always records itself in the ledger, with the replaced and the replacement counts.
    if($null -ne $corrected){
        $record=New-SBTaskRunRecord -Task $task -Before $before -Executor $Executor -Created -Reason ('Evidence correction: '+$corrected)
        $record.event='evidence'
    }
    # A reviewed analysis that rewrites the task records itself even when status and execution stay the same.
    if(!$record -and ($Fields.ContainsKey('Decisions') -or $Fields.ContainsKey('Acceptance'))){$record=New-SBTaskRunRecord -Task $task -Executor $Executor -Created;$record.event='analysis'}
    @{taskId=$TaskId;status=$task.status;closing=$closing;record=$record}
}
function Invoke-SBTrackerTaskBatch {
    # #595: several task updates on one tracker read, one graph validation and one transaction (tracker, archive, ledger and -ExtraOperations).
    # Items: @{TaskId=...; <update fields>; Executor=...}. A failing item throws tracker.batch.item naming its position and task; nothing is written.
    [CmdletBinding()]
    param([string]$BrainRoot,[string]$Identity,[string]$WorkingRepository,[Parameter(Mandatory)][object[]]$Items,[object[]]$ExtraOperations=@(),[string]$BackupRoot,[switch]$WhatIf,[string]$ExpectedHash)
    if(!$Items.Count){throw (New-SBError 'tracker.batch.empty')}
    $apply={
        param([int]$Count)
        $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity '' $WorkingRepository
        if($ExpectedHash -and $target.hash -cne $ExpectedHash){throw (New-SBError 'tracker.batch.changed')}
        $archive=Read-SBTrackerArchive $target.path $target.identity
        $records=@();$results=@();$seen=@{}
        for($i=0;$i -lt $Count;$i++){
            $item=$Items[$i]
            $label=if($item -is [Collections.IDictionary] -and $item.Contains('TaskId')){[string]$item.TaskId}else{'?'}
            try{
                if($item -isnot [Collections.IDictionary] -or !$label){throw (New-SBError 'tracker.batch.shape')}
                $fields=@{};foreach($key in $item.Keys){if($key -notin @('TaskId','Executor')){$fields[$key]=$item[$key]}}
                $executor=if($item.Contains('Executor')){$item.Executor}else{$null}
                $edit=Edit-SBTrackerTaskFields $target $archive $label $fields $executor
                if($seen.ContainsKey($edit.taskId)){throw (New-SBError 'tracker.batch.duplicate')}
                $seen[$edit.taskId]=$true
            }catch{throw (New-SBError 'tracker.batch.item' @(($i+1),$label,$_.Exception.Message))}
            if($edit.record){$records+=,$edit.record}
            $entry=@{index=($i+1);taskId=$edit.taskId;status=$edit.status}
            if($edit.closing){$entry.closureAdvice=Get-SBClosureAdvice (Split-Path $target.path)}
            $results+=,$entry
        }
        @{target=$target;archive=$archive;records=$records;results=$results}
    }
    $state=& $apply $Items.Count
    try{$saved=Save-SBTrackerData $state.target $state.target.data $BackupRoot -WhatIf -Archive $state.archive -LedgerRecords $state.records -ExtraOperations $ExtraOperations}
    catch{
        # The whole-graph check failed: replay the prefixes to name the first item that breaks it.
        $failure=$_
        for($k=1;$k -le $Items.Count;$k++){
            $prefix=& $apply $k
            try{[void](Save-SBTrackerData $prefix.target $prefix.target.data $BackupRoot -WhatIf -Archive $prefix.archive -LedgerRecords $prefix.records)}
            catch{throw (New-SBError 'tracker.batch.item' @($k,[string]$Items[$k-1].TaskId,$_.Exception.Message))}
        }
        throw $failure
    }
    $ops=@(@{path=$state.target.path;expected=$state.target.hash;bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $saved.data))})+@($saved.extraOperations)
    $result=@{applied=$false;path=$state.target.path;data=$saved.data;operations=$ops;items=$state.results;trackerHash=$state.target.hash}
    if($WhatIf){return $result}
    if(!$BackupRoot){$BackupRoot=Resolve-SBTrackerBackupRoot $state.target.brainRoot}
    [IO.Directory]::CreateDirectory($BackupRoot)|Out-Null
    foreach($op in @($ops)){[IO.Directory]::CreateDirectory((Split-Path $op.path))|Out-Null}
    $result.manifest=Invoke-SBParaTransaction -Operations $ops -BackupRoot $BackupRoot -BrainRoot $state.target.brainRoot
    $result.applied=$true
    $result
}
function Invoke-SBTaskRunBackfill {
    # Copies the runner reports of this workstation that the ledger does not hold yet into history/task-runs.jsonl (idempotent: one record per
    # report folder and task). Preview unless -Apply; tasks without any record keep the "unknown" executor in the registry.
    param([string]$BrainRoot,[string]$Identity,$Ledger=@(),$Reports=@(),$Archive=@(),[string]$BackupRoot,[switch]$Apply)
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity
    $known=@{}
    foreach($r in @($Ledger)){
        $known['r|'+[string]$r.recordId]=$true
        if($r['outcome'] -is [Collections.IDictionary] -and $r.outcome['folder']){$known['f|'+[string]$r.taskId+'|'+[string]$r.outcome.folder]=$true}
    }
    $new=@(@($Reports)|Where-Object {$_ -and !$known.ContainsKey('r|'+[string]$_.recordId) -and !$known.ContainsKey('f|'+[string]$_.taskId+'|'+[string]$_.outcome['folder'])})
    $result=[ordered]@{repository=$Identity;ledger=(Get-SBTaskLedgerPath $target.path);existing=@($Ledger).Count;reports=@($Reports).Count;added=$new.Count;applied=$false;taskIds=@($new|ForEach-Object {[string]$_.taskId}|Select-Object -Unique)}
    if(!$Apply -or !$new.Count){return $result}
    if(!$BackupRoot){$BackupRoot=Resolve-SBTrackerBackupRoot $target.brainRoot}
    $op=Get-SBTaskLedgerOperation $target.path @($new|Sort-Object {[string]$_.at})
    [IO.Directory]::CreateDirectory((Split-Path $op.path))|Out-Null
    $result.manifest=Invoke-SBParaTransaction -Operations @($op) -BackupRoot $BackupRoot -BrainRoot $target.brainRoot
    $result.applied=$true
    $result
}
function Invoke-SBTrackerTaskChanges {
    # Status changes with evidence applied by another writer (memory cycle) in its own transaction: the same closure signal, archive and
    # ledger as the CLI writers. -ExpectedHash guards the tracker revision the caller planned on; -ExtraOperations join the transaction.
    param([string]$BrainRoot,[string]$Identity,[Parameter(Mandatory)][object[]]$Changes,[string]$ExpectedHash,[object[]]$ExtraOperations=@(),[string]$BackupRoot,[switch]$Apply,$Executor)
    $target=Resolve-SBTrackerWriteTarget $BrainRoot $Identity
    if($ExpectedHash -and $target.hash -cne $ExpectedHash){throw (New-SBError 'cycle.conflict' @('tracker revision'))}
    $archive=Read-SBTrackerArchive $target.path $target.identity
    $records=@()
    foreach($change in $Changes){
        $task=Get-SBTrackerTaskForUpdate $target $archive $change.id
        $before=Get-SBTaskLedgerSnapshot $task
        if($change.status -cnotin @('todo','in_progress','blocked','done','cancelled')){throw (New-SBError 'cycle.invalid' @('task status'))}
        if($change.status -eq 'done'){
            if(!$change.ContainsKey('verifiedAcceptance') -or (ConvertTo-SBJson @($change.verifiedAcceptance)) -cne (ConvertTo-SBJson @($task.acceptance))){throw (New-SBError 'cycle.invalid' @('task acceptance evidence'))}
            Set-SBTaskClosure $target.data $task.id
        }
        $task.status=$change.status
        $task.evidence+=@{reference=$change.evidenceReference;outcome='passed'}
        $records+=,(New-SBTaskRunRecord -Task $task -Before $before -Executor $Executor)
    }
    Save-SBTrackerData $target $target.data $BackupRoot -WhatIf:(!$Apply) -Archive $archive -ExtraOperations $ExtraOperations -LedgerRecords $records
}

Export-ModuleMember -Function @(
    'Test-SBTrackerPolicy',
    'Test-SBTrackerData',
    'Assert-SBTrackerWriteData',
    'Read-SBTrackerArchive',
    'Resolve-SBTrackerTaskId',
    'New-SBEnrichmentUpdate',
    'Move-SBTerminalTrackerTasks',
    'Get-SBTrackerRelatedData',
    'Resolve-SBTracker',
    'New-SBTrackerTask',
    'Read-SBTrackerReview',
    'ConvertTo-SBTracker',
    'ConvertTo-SBTrackerHistoryRecord',
    'Get-SBTrackerLastSeq',
    'Remove-SBOriginDependencyRepository',
    'Convert-SBTrackerLocation',
    'Get-SBCuratedReferenceIssues',
    'Get-SBTrackerAuthorityIssues',
    'Resolve-SBTrackerBackupRoot',
    'Set-SBTrackerTaskStatus',
    'Get-SBClosureMemoryPending',
    'New-SBTrackerTaskEntry',
    'Get-SBTaskReadiness',
    'Set-SBTaskReadiness',
    'Invoke-SBTrackerRenumber',
    'Get-SBTrackerHistoryMessages',
    'Invoke-SBTrackerHistoryMigration',
    'Update-SBTrackerTask',
    'Invoke-SBTrackerTaskBatch',
    'Invoke-SBTrackerTaskChanges',
    'Invoke-SBTaskRunBackfill',
    'Set-SBTaskClosure',
    'Get-SBClosureAdvice',
    'ConvertTo-SBTaskEvidence',
    'ConvertTo-SBEvidenceCorrection',
    'ConvertTo-SBTaskEvidenceList',
    'ConvertTo-SBTaskDecisions',
    'Get-SBTaskRequiresValues',
    'ConvertTo-SBTaskRequires'
)
