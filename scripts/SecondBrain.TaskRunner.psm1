#requires -Version 7.5
# Task runner: pure selection of autonomous tracker tasks and the fixed prompt given to each fresh agent session.
# No file I/O here: scripts/run-ready-tasks.ps1 owns process launch, work folders and reports.
# The read-scope guard (#382) reads only the session variable that the runner sets in the agent's environment (#475: no cross-repository allowlist).
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Knowledge.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.ComputerUse.psm1')
Add-SBMessages @{
    'isolation.cross.refused' = @{it='Isolamento per progetto: la vista globale o la ricerca senza progetto risolto e rifiutata; indicare il repository in lavoro';en='Project isolation: the global view or a search without a resolved project is refused; give the working repository'}
    'runner.scope.global' = @{it='Lettura globale rifiutata in una sessione del runner per {0}: -All, -AllDossiers e all=true non sono consentiti; usare il repository del task';en='Global read refused in a runner session for {0}: -All, -AllDossiers and all=true are not allowed; use the task repository'}
    'runner.scope.repository' = @{it='Lettura rifiutata in una sessione del runner: {0} non e il repository del task ({1})';en='Read refused in a runner session: {0} is not the task repository ({1})'}
    'runner.scope.write' = @{it='Scrittura rifiutata in una sessione del runner: {0} non e il repository del task ({1})';en='Write refused in a runner session: {0} is not the task repository ({1})'}
    'runner.scope.dossier' = @{it='Dossier rifiutato in una sessione del runner: {0} non appartiene al repository del task ({1})';en='Dossier refused in a runner session: {0} does not belong to the task repository ({1})'}
}
$script:SBRunnerScopeVariables = @{repository='SECONDBRAIN_RUNNER_REPOSITORY'}
$script:SBRunnerExcludedStreams = @('qualifica-finale','intervento-su-richiesta','coordinamento-prodotti')
function Get-SBRunnerScopeVariables { $script:SBRunnerScopeVariables.Clone() }
function Get-SBRunnerReadScope {
    # Set by run-ready-tasks.ps1 in the agent process only; absent in sessions started by a person, where nothing is restricted.
    $repo=[Environment]::GetEnvironmentVariable($script:SBRunnerScopeVariables.repository)
    if([string]::IsNullOrWhiteSpace($repo)){return $null}
    @{repository=$repo.Trim()}
}
function Assert-SBRunnerReadScope([switch]$Global,[string]$Repository,[string]$Dossier,[string]$BrainRoot,[switch]$Write){
    # Code-level perimeter of a runner session: no global views, reads and writes only of the task repository.
    $scope=Get-SBRunnerReadScope
    if(!$scope){return}
    if($Global){throw (New-SBError 'runner.scope.global' @($scope.repository))}
    if($Repository -and $Repository -ine $scope.repository){
        if($Write){throw (New-SBError 'runner.scope.write' @($Repository,$scope.repository))}
        throw (New-SBError 'runner.scope.repository' @($Repository,$scope.repository))
    }
    if($Dossier){
        $full=if([IO.Path]::IsPathRooted($Dossier)){$Dossier}else{Join-Path $BrainRoot $Dossier}
        $full=[IO.Path]::GetFullPath($full).TrimEnd('\','/')
        $allowed=@(@($scope.repository)|ForEach-Object {
            try{[IO.Path]::GetFullPath((Join-Path $BrainRoot (Resolve-SBWorkingDossier $BrainRoot $_))).TrimEnd('\','/')}catch{$null}
        }|Where-Object {$_})
        if(@($allowed|Where-Object {[string]::Equals($_,$full,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0){throw (New-SBError 'runner.scope.dossier' @($Dossier,$scope.repository))}
    }
}
function Test-SBProjectIsolation([string]$BrainRoot){
    # Strict isolation per project (#475): reads stay in the working project; 03-resources is the only common area. There is no switch to lift it.
    $true
}
function Assert-SBProjectIsolation([string]$BrainRoot){
    if(Test-SBProjectIsolation $BrainRoot){throw (New-SBError 'isolation.cross.refused')}
}
function Get-SBRunnerValue($Object,[string]$Name){
    if($null -eq $Object){return $null}
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p){return $null}
    $p.Value
}
function Get-SBRunnerExcludedStreams { ,$script:SBRunnerExcludedStreams }
function Get-SBRunnerOpenDecisions([string]$TrackerPath){
    # #610: open dec- decisions of the tracker's dossier (decisions.json), by task (context.taskId) and as a set of IDs (key '#open').
    # An unreadable file parks nothing here: -Check reports it.
    $map=@{'#open'=@()}
    if(!$TrackerPath){return $map}
    $path=Join-Path (Split-Path $TrackerPath) 'decisions.json'
    if(![IO.File]::Exists($path)){return $map}
    $data=$null;try{$data=[IO.File]::ReadAllText($path)|ConvertFrom-Json -AsHashtable -DateKind String}catch{return $map}
    foreach($r in @($data['decisions'])){
        if($r -isnot [Collections.IDictionary] -or [string]$r['status'] -ne 'open'){continue}
        $map['#open']+=[string]$r.id
        $context=$r['context']
        if($context -is [Collections.IDictionary] -and [string]$context['taskId']){$k=[string]$context.taskId;if(!$map.ContainsKey($k)){$map[$k]=@()};$map[$k]+=[string]$r.id}
    }
    $map
}
function Get-SBRunnerExclusionReason($Task,[switch]$AllowComputerUse,$OpenDecisions){
    # Why a task is not runnable, as a stable code ($null when it is): status, execution, stream:<name>, decision:<dec ids> or awaiting:<value>.
    $status=Get-SBRunnerValue $Task 'status'
    if($status -ne 'todo'){return "status:$status"}
    $execution=Get-SBRunnerValue $Task 'execution'
    if($execution -ne 'autonomous'){return "execution:$(if($execution){$execution}else{'unset'})"}
    $ext=Get-SBRunnerValue $Task 'extensions'
    $stream=Get-SBRunnerValue $ext 'stream'
    if($stream -in $script:SBRunnerExcludedStreams){return "stream:$stream"}
    # #610: a task with an open dec- decision (its own in decisions.json, or the one it links) is parked; answering it makes the task
    # eligible again. Its dependants are not ready while it is open, so independent tasks keep running.
    if($OpenDecisions){
        $taskId=[string](Get-SBRunnerValue $Task 'id');$linked=[string](Get-SBRunnerValue $ext 'decision')
        $ids=@(@(if($OpenDecisions.ContainsKey($taskId)){$OpenDecisions[$taskId]})+@(if($linked -and $linked -in @($OpenDecisions['#open'])){$linked})|Where-Object {$_}|Sort-Object -Unique)
        if($ids.Count){return 'decision:'+($ids -join ',')}
    }
    $awaiting=Get-SBRunnerValue $ext 'awaiting'
    if($awaiting -and $awaiting -notin @('structural-completion')){return "awaiting:$awaiting"}
    # Computer use needs an attended session: `claude -p` cannot approve apps, and no IDE documents a persistent pre-approval for it (Codex on Windows aside).
    # A task that declares extensions.requires=computer-use is left for an attended session instead of failing midway.
    $requires=@(Get-SBRunnerValue $ext 'requires'|Where-Object {$_}|ForEach-Object {[string]$_})
    # -AllowComputerUse comes from the preflight of the capability table (SecondBrain.ComputerUse.psm1): the agent has a documented, present pre-approval.
    if((Get-SBComputerUseRequirement) -in $requires -and !$AllowComputerUse){return 'requires:computer-use'}
    $null
}
function Test-SBRunnableTask($Task,[switch]$AllowComputerUse,$OpenDecisions){
    # A task is runnable only when it is todo, explicitly autonomous, outside final qualification/on-request/product streams and not waiting on a person.
    $null -eq (Get-SBRunnerExclusionReason $Task -AllowComputerUse:$AllowComputerUse -OpenDecisions $OpenDecisions)
}
function Get-SBRunnerExclusions($Tasks,[switch]$AllowComputerUse,$OpenDecisions){
    # Ready tasks the runner will not run, each with its reason, for the preview report.
    @($Tasks|ForEach-Object {$r=Get-SBRunnerExclusionReason $_ -AllowComputerUse:$AllowComputerUse -OpenDecisions $OpenDecisions;if($r){[ordered]@{id=[string](Get-SBRunnerValue $_ 'id');seq=Get-SBRunnerValue $_ 'seq';reason=$r}}})
}
function Select-SBRunnableTasks($Tasks,[int]$MaxTasks=3,[switch]$AllowComputerUse,$OpenDecisions){
    $rank=@{P0=0;P1=1;P2=2;P3=3;P4=4}
    $sel=@($Tasks|Where-Object {Test-SBRunnableTask $_ -AllowComputerUse:$AllowComputerUse -OpenDecisions $OpenDecisions}|Sort-Object @{e={$r=$rank[[string](Get-SBRunnerValue $_ 'priority')];if($null -eq $r){9}else{$r}}},@{e={[int](Get-SBRunnerValue $_ 'seq')}})
    if($MaxTasks -gt 0 -and $sel.Count -gt $MaxTasks){$sel=@($sel[0..($MaxTasks-1)])}
    ,$sel
}
function ConvertTo-SBFindingKey([string]$Title){
    # #611: the normalized title of a finding or task (no "#NNN - " prefix with an em dash or hyphen, lower case, letters and digits only, single spaces).
    $t=([string]$Title) -replace '^\s*#\d+\s*\p{Pd}\s*',''
    (($t.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+',' ').Trim())
}
function Read-SBRunnerFindings([string]$Path){
    # #611: findings.json written by the agent in its attempt folder. Each entry is valid (title with a letter, reproduction, evidence,
    # at least one acceptance criterion) or invalid with its reason: invalid entries are reported, never turned into tasks.
    $out=[ordered]@{present=$false;error=$null;findings=@()}
    if(!$Path -or !(Test-Path -LiteralPath $Path -PathType Leaf)){return $out}
    $out.present=$true
    $data=try{Get-Content -LiteralPath $Path -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 20}catch{$null}
    if($data -isnot [Collections.IDictionary] -or $data['findings'] -isnot [Collections.IList]){$out.error='unreadable';return $out}
    $i=0
    foreach($f in @($data['findings'])){
        $i++
        $entry=[ordered]@{index=$i;title=$null;key=$null;reproduction=$null;evidence=$null;acceptance=@();existing=$null;valid=$false;reason=$null}
        if($f -isnot [Collections.IDictionary]){$entry.reason='not-an-object';$out.findings+=,$entry;continue}
        $entry.title=([string]$f['title']).Trim();$entry.reproduction=([string]$f['reproduction']).Trim();$entry.evidence=([string]$f['evidence']).Trim()
        $entry.acceptance=@(@($f['acceptance'])|ForEach-Object {([string]$_).Trim()}|Where-Object {$_})
        $entry.existing=if($f['existing']){([string]$f['existing']).Trim()}else{$null}
        $entry.key=ConvertTo-SBFindingKey $entry.title
        $missing=@()
        if($entry.title -notmatch '\p{L}' -or $entry.title.Length -gt 200){$missing+='title'}
        if(!$entry.reproduction){$missing+='reproduction'}
        if(!$entry.evidence){$missing+='evidence'}
        if(!$entry.acceptance.Count){$missing+='acceptance'}
        if($missing.Count){$entry.reason='missing:'+($missing -join ',')}else{$entry.valid=$true}
        $out.findings+=,$entry
    }
    $out
}
function Find-SBFollowUpMatch($Finding,$Tasks,[string]$SourceId){
    # #611: duplicate detection before any follow-up is created, deterministic only: the existing task the agent names (any status but
    # cancelled), an open task with the same normalized title, or an earlier follow-up of the same source with the same title (not cancelled).
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){$o[$n]}else{Get-SBRunnerValue $o $n}}
    $all=@(@($Tasks)|Where-Object {$_})
    if($Finding.existing){
        $hit=@($all|Where-Object {[string](& $field $_ 'id') -ieq $Finding.existing -and [string](& $field $_ 'status') -ne 'cancelled'})
        if($hit.Count){return [ordered]@{id=[string](& $field $hit[0] 'id');rule='explicit'}}
    }
    foreach($t in $all){
        $status=[string](& $field $t 'status')
        if($status -eq 'cancelled' -or [string](& $field $t 'id') -ieq $SourceId){continue}
        $ext=& $field $t 'extensions'
        $sameSource=$ext -and [string](& $field $ext 'followUpOf') -ieq $SourceId
        if((ConvertTo-SBFindingKey ([string](& $field $t 'title'))) -ceq $Finding.key -and ($status -ne 'done' -or $sameSource)){
            return [ordered]@{id=[string](& $field $t 'id');rule=$(if($sameSource){'follow-up'}else{'title'})}
        }
    }
    $null
}
function New-SBTaskRunPrompt($Task,[string]$ScriptsRoot,[string]$CheckoutPath,[string]$FindingsPath){
    $id=Get-SBRunnerValue $Task 'id'
    # With a scripts root and a checkout (multi-repository run) the agent starts in a product checkout, where scripts/knowledge.ps1 does not exist:
    # the extra line gives it the absolute SecondBrain tools and the checkout that resolves the dossier.
    $where=if($ScriptsRoot -and $CheckoutPath){"Strumenti SecondBrain in $ScriptsRoot (usa $ScriptsRoot\knowledge.ps1 con -CheckoutPath `"$CheckoutPath`" al posto di scripts/knowledge.ps1), oppure i tool MCP secondbrain."}else{$null}
    # Owner decisions recorded by the orchestrator analysis (extensions.decisions): the agent applies them and never asks again.
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){$o[$n]}else{Get-SBRunnerValue $o $n}}
    $decisions=@(@(& $field (& $field $Task 'extensions') 'decisions')|Where-Object {$_ -and (& $field $_ 'answer')})
    $decided=if($decisions.Count){
        @('Decisioni della persona (gia prese: applicale e non chiederle di nuovo):')+@($decisions|ForEach-Object {'- '+([string](& $field $_ 'question')).Trim()+' -> '+([string](& $field $_ 'answer')).Trim()}) -join "`n"
    }else{$null}
    @(
        "Esegui SOLO il task $id (#$(Get-SBRunnerValue $Task 'seq')) del tracker SecondBrain, in questa sessione nuova.",
        $where,
        $decided,
        'Procedura: leggi AGENTS.md, carica il contesto con scripts/knowledge.ps1 -Startup, leggi il task con scripts/knowledge.ps1 -Task, esegui il lavoro, verifica ogni criterio di accettazione con strumenti disponibili e funzionanti, poi aggiorna lo stato con scripts/knowledge.ps1 -UpdateTaskId.',
        'Perimetro: lavora solo sul repository di questo checkout e sul suo tracker; non leggere, prendere o aggiornare task di altri repository e non usare -All, -AllDossiers, all=true e non indicare -Repository di un altro repository.',
        'Divieti: nessun commit, push, pubblicazione o cancellazione; nessuna applicazione di SYS05 o di pulizie; nessun altro task. Se serve una conferma o una prova live, fermati e riporta il limite nello stato del task senza chiuderlo.',
        'Closing as done needs evidence: pass -Evidence "<check>|passed" for each verified criterion in the same update; a task closed as done without passed evidence from this session is reopened by the runner.',
        $(if($FindingsPath){"Unresolved problems: before ending, write every actionable problem you found and did not resolve to the findings file $FindingsPath as {`"findings`":[{`"title`":`"...`",`"reproduction`":`"...`",`"evidence`":`"...`",`"acceptance`":[`"...`"],`"existing`":`"<task id or null>`"}]}. Name an existing task in existing when it already covers the problem. Do not create follow-up tasks yourself: the runner matches existing tasks and records linked follow-ups."}else{$null}),
        'Chiudi con un riepilogo breve: esito per criterio, verifiche eseguite, limiti.'
    ).Where({$_}) -join "`n"
}
function Get-SBRunnerAcceptance($Task,[DateTimeOffset]$AttemptStartedAt) {
    # #613: a successful agent exit is not task completion. verified = done with passed evidence recorded during this attempt (a few
    # seconds of clock slack); unverified = done without it; open = any other status (the task is still open, whatever the process did).
    # Tracker reads give hashtables (Read-SBJson) or objects (CLI JSON): read a field from either.
    $field={param($o,[string]$n) if($o -is [Collections.IDictionary]){$o[$n]}else{Get-SBRunnerValue $o $n}}
    $status=[string](& $field $Task 'status')
    if($status -ne 'done'){return 'open'}
    $since=$AttemptStartedAt.AddSeconds(-5)
    foreach($e in @(& $field $Task 'evidence')){
        if(!$e){continue}
        $outcome=[string](& $field $e 'outcome');$at=[DateTimeOffset]::MinValue
        if($outcome -eq 'passed' -and [DateTimeOffset]::TryParse([string](& $field $e 'observedAt'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$at) -and $at -ge $since){return 'verified'}
    }
    'unverified'
}
Export-ModuleMember -Function @('Get-SBRunnerOpenDecisions','Get-SBRunnerAcceptance','Get-SBRunnerValue','Test-SBProjectIsolation','Assert-SBProjectIsolation','Get-SBRunnerExcludedStreams','Test-SBRunnableTask','Get-SBRunnerExclusionReason','Get-SBRunnerExclusions','Select-SBRunnableTasks','New-SBTaskRunPrompt','ConvertTo-SBFindingKey','Read-SBRunnerFindings','Find-SBFollowUpMatch','Get-SBRunnerScopeVariables','Get-SBRunnerReadScope','Assert-SBRunnerReadScope')
