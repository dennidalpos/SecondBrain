#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Trace.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'knowledge.tasks.unselected' = @{ en = 'No task selected. Use -Tasks to choose work and -Task for complete details.' }
    'knowledge.tracker.data' = @{ en = 'Tracker data not available' }
    'knowledge.paging.invalid' = @{ en = 'Offset and Limit must be non-negative integers' }
    'knowledge.record.missing' = @{ en = 'repository.json missing' }
    'knowledge.dossier.invalid' = @{ en = 'Invalid dossier: run secondbrain.ps1 -Check for details' }
    'knowledge.repository.required' = @{ en = 'Repository not specified: give the working repository or -All for the read-only global view' }
    'knowledge.dossier.none' = @{ en = 'No active dossier for repository: {0}' }
    'knowledge.dossier.ambiguous' = @{ en = 'Dossier not uniquely resolved for repository: {0}' }
    'knowledge.lifecycle.invalid' = @{ en = 'Invalid lifecycle in repository.json: only greenfield is allowed' }
    'knowledge.tracker.unavailable' = @{ en = 'Tracker not available for the dossier' }
    'knowledge.task.ambiguous' = @{ en = 'Several tasks match: {0}' }
    'knowledge.task.notfound' = @{ en = 'Task not found: {0}. List tasks with knowledge.ps1 -Tasks' }
    'knowledge.source.invalid' = @{ en = 'Invalid source: use context, memory, history or history/<folder>' }
    'knowledge.section.notfound' = @{ en = 'Section not found: {0}' }
    'knowledge.dossier.unspecified' = @{ en = 'Dossier not specified: run from the repository checkout or pass -Dossier (absolute or relative to the SecondBrain root)' }
    'knowledge.dossier.archived' = @{ en = 'Archived dossier: compaction is not implicitly authorized' }
    'knowledge.candidate.review' = @{ en = 'Candidate requires explicit agent review and a reason' }
    'knowledge.candidate.repository' = @{ en = 'Candidate belongs to another repository' }
    'knowledge.source.changed' = @{ en = 'Source changed after preparation: {0}' }
    'knowledge.summary.missing' = @{ en = 'Summary missing: {0}' }
    'knowledge.section.name' = @{ en = '{0}' }
    'knowledge.section.essential' = @{ en = 'Essential section missing: {0}' }
    'knowledge.original.diverged' = @{ en = 'Archived original diverges' }
    'knowledge.candidate.tasks' = @{ en = 'The candidate omits open tasks: regenerate the projection' }
    'knowledge.budget.exceeded' = @{ en = 'Budget exceeded: refine the summary without truncating information' }
    'knowledge.startup.compacted' = @{ en = 'Package compacted: retrieve sections and tasks with -Section, -Tasks, -Task or -Startup -Profile Full' }
    'knowledge.budget.alert' = @{ en = 'Startup context at {0}% of the {1}-character cap (total {2}: package {3}, AGENTS.md and global directive {4}): propose dossier.compact (sb compact) before adding more context; nothing is compacted without confirmation' }
    'knowledge.startup.minimum' =@{ en = 'Budget too small for Slim startup. Minimum characters: {0}' }
}

# Source applicability of a dossier (#492): validates authoritative-sources.json against the schema and the dossier identity,
# then lists only applicable and conditional sources (not-applicable and unassessed stay in the file).
function Get-SBDossierSourceLine([string]$Dossier,[string]$BrainRoot,$Record) {
    $path=Join-Path $Dossier 'authoritative-sources.json'
    if(!(Test-Path -LiteralPath $path)){return $null}
    $prefix='- [Applicabilità delle fonti](authoritative-sources.json): '
    $map=Read-SBJson $path $null
    $schema=if($BrainRoot){Join-Path $BrainRoot 'config/source-applicability.schema.json'}else{''}
    $valid=$map -and $map.ContainsKey('sources') -and $map.repository -ceq $Record.identity
    if($valid -and $schema -and (Test-Path -LiteralPath $schema)){$valid=[bool](Test-Json -Json (Read-SBText $path) -SchemaFile $schema -ErrorAction SilentlyContinue)}
    if(!$valid){return $prefix+'scheda non valida o di un altro repository: eseguire sources.ps1 -Check prima di usarla.'}
    $listed=@($map.sources|Where-Object {$_.applicability -in @('applicable','conditional')}|ForEach-Object {$_.sourceId+$(if($_.applicability -eq 'conditional'){' (condizionale)'}else{''})})
    if(!$listed.Count){return $prefix+'no applicable source declared.'}
    $prefix+'fonti applicabili: '+($listed -join ', ')+'; motivazioni e versioni nel file.'
}
function Get-SBDossierTOC([string]$Dossier,[string]$BrainRoot='') {
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.record.missing')}
    $lines=@('# Dossier index','',('Repository: `'+$record.identity+'`'),'','## Selective startup','',
        '- [Current context](context.md): state, constraints and next step.',
        '- [Essential memory](memory.md): durable decisions and gotchas.',
        '- [Metadata and task source](repository.json): resolve the tracker; read only the relevant projection.',
        '- [History](history/index.md): originals and evidence on request; do not load in full at startup.','','## Deep dives','')
    foreach($directory in @('knowledge','topics')){
        $root=Join-Path $Dossier $directory
        if(Test-Path -LiteralPath $root){foreach($file in Get-ChildItem -LiteralPath $root -File -Filter '*.md'|Sort-Object Name){$lines+='- ['+$file.BaseName+']('+[Uri]::EscapeUriString($directory+'/'+$file.Name)+'): read for this topic.'}}
    }
    $sourceLine=Get-SBDossierSourceLine $Dossier $BrainRoot $record
    if($sourceLine){$lines+=$sourceLine}
    if(Test-Path -LiteralPath (Join-Path $Dossier 'knowledge-index.json')){$lines+='- [Derived topic index](knowledge-index.json): revisions and references; verify sources before using them.'}
    ($lines -join "`n")+"`n"
}
function Get-SBDossierHistoryIndex([string]$Dossier) {
    $history=Join-Path $Dossier 'history';$lines=@('# History index','','Load only the relevant evidence; this content does not renew authorizations.','')
    if(Test-Path -LiteralPath $history){
        if([IO.File]::Exists((Join-Path $history 'tracker-archive.json'))){$lines+='- [Archived tasks](tracker-archive.json)'}
        foreach($directory in Get-ChildItem -LiteralPath $history -Directory|Sort-Object Name){$lines+='- ['+$directory.Name+']('+[Uri]::EscapeUriString($directory.Name+'/')+')'}
    }
    ($lines -join "`n")+"`n"
}
function Get-SBTaskProjection($Tracker,[string[]]$TaskIds=@(),[switch]$IncludeAcceptance,[switch]$ReadyOnly,$RelatedTrackers=@{}) {
    $active=@($Tracker.tasks|Where-Object {$_.status -notin @('done','cancelled') -and (!$TaskIds.Count -or $_.id -in $TaskIds)})
    if($ReadyOnly){
        $active=@($active|Where-Object {$_.status -notin @('blocked','unknown')})
        $myRepo=''
        if($Tracker -is [Collections.IDictionary]){if($Tracker.ContainsKey('repository')){$myRepo=[string]$Tracker.repository}}
        elseif($Tracker.PSObject.Properties['repository']){$myRepo=[string]$Tracker.repository}
        $taskMap=@{}
        foreach($t in $Tracker.tasks){
            $taskMap[[string]$t.id]=[string]$t.status
            if($myRepo){$taskMap[$myRepo+'#'+[string]$t.id]=[string]$t.status}
        }
        if($RelatedTrackers){
            foreach($relKey in $RelatedTrackers.Keys){
                $relDoc=$RelatedTrackers[$relKey]
                $relRepo=[string]$relKey
                if($relDoc -is [Collections.IDictionary]){if($relDoc.ContainsKey('repository')){$relRepo=[string]$relDoc.repository}}
                elseif($relDoc.PSObject.Properties['repository']){$relRepo=[string]$relDoc.repository}
                $relTasks=@()
                if($relDoc -is [Collections.IDictionary]){if($relDoc.ContainsKey('tasks')){$relTasks=@($relDoc.tasks)}}
                elseif($relDoc.PSObject.Properties['tasks']){$relTasks=@($relDoc.tasks)}
                foreach($t in $relTasks){$taskMap[$relRepo+'#'+[string]$t.id]=[string]$t.status}
            }
        }
        $filtered=@()
        foreach($candidate in $active){
            $ready=$true
            if($candidate.dependencies){
                foreach($dep in @($candidate.dependencies)){
                    $depId=''
                    $depRepo=$myRepo
                    if($dep -is [string]){$depId=$dep}
                    elseif($dep -is [Collections.IDictionary]){
                        if($dep.ContainsKey('id')){$depId=[string]$dep.id}
                        if($dep.ContainsKey('repository') -and $dep.repository){$depRepo=[string]$dep.repository}
                    }else{
                        if($dep.PSObject.Properties['id']){$depId=[string]$dep.id}
                        if($dep.PSObject.Properties['repository'] -and $dep.repository){$depRepo=[string]$dep.repository}
                    }
                    $status=$null
                    if($depRepo -and $taskMap.ContainsKey($depRepo+'#'+$depId)){$status=$taskMap[$depRepo+'#'+$depId]}
                    elseif($taskMap.ContainsKey($depId)){$status=$taskMap[$depId]}
                    if(!$status -or $status -notin @('done','completed')){$ready=$false;break}
                }
            }
            if($ready){$filtered+=$candidate}
        }
        $active=$filtered
    }
    @($active|ForEach-Object {
        $task=@{id=$_.id;title=$_.title;status=$_.status;priority=$_.priority;dependencies=$_.dependencies;blocker=$(if($_.extensions.ContainsKey('stateReason')){$_.extensions.stateReason}else{''})}
        if($_.ContainsKey('seq')){$task.seq=$_.seq}
        if($IncludeAcceptance){$task.acceptance=$_.acceptance}
        $task
    })
}
# Dossier Markdown tiers: a `## ` section is historical if its title ends in (history) (or the legacy Italian (storico)) or its first nonempty line is <!-- sb:tier=history -->.
# Text before the first section and unmarked sections are essential. Without markers, the entire file is essential.
function Split-SBMarkdownH2([string]$Text) {
    $normalized=$Text.Replace("`r`n","`n")
    $start=0;$fence=''
    foreach($line in [regex]::Matches($normalized,'(?m)^[^\n]*')){
        if(!$fence -and $line.Index -gt $start -and $line.Value.StartsWith('## ')){
            $normalized.Substring($start,$line.Index-$start)
            $start=$line.Index
        }
        if($line.Value -match '^ {0,3}(?<marker>`{3,}|~{3,})'){
            $marker=$Matches.marker
            if(!$fence){$fence=$marker}
            elseif($marker[0] -eq $fence[0] -and $marker.Length -ge $fence.Length -and $line.Value.Trim() -eq $marker){$fence=''}
        }
    }
    if($normalized.Length -gt $start){$normalized.Substring($start)}
}
$script:SBContextSections = @(
    @{ english='Constraints'; italian='Vincoli'; priority=0 }
    @{ english='Current state'; italian='Stato corrente'; priority=1 }
    @{ english='Open issues'; italian='Problemi aperti'; priority=2 }
    @{ english='Next step'; italian='Prossimo passo'; priority=2 }
)

function Get-SBMarkdownSectionTitle([string]$Chunk) {
    if($Chunk.StartsWith('## ')){return ($Chunk -split "`n",2)[0].Substring(3).Trim()}
    return ''
}

function Get-SBMissingContextSection([string]$Text) {
    $titles=@(Split-SBMarkdownH2 $Text | ForEach-Object { Get-SBMarkdownSectionTitle $_ })
    foreach($section in $script:SBContextSections){
        if($section.english -notin $titles -and $section.italian -notin $titles){
            Get-SBMessage 'knowledge.section.name' @($section.english,$section.italian)
        }
    }
}

function Split-SBTieredMarkdown([string]$Text) {
    $Text=Remove-SBPrivateText $Text
    $essential=[Text.StringBuilder]::new();$history=[Text.StringBuilder]::new();$titles=@()
    foreach($chunk in (Split-SBMarkdownH2 $Text)){
        if(!$chunk){continue}
        $isHistory=$false;$title=''
        if($chunk.StartsWith('## ')){
            $lines=$chunk -split "`n"
            $title=$lines[0].Substring(3).Trim()
            $firstBody=@($lines|Select-Object -Skip 1|Where-Object {$_.Trim()}|Select-Object -First 1)
            $isHistory=($title -match '(?i)\((?:storico|history)\)\s*$') -or ($firstBody.Count -eq 1 -and $firstBody[0].Trim() -match '^<!--\s*sb:tier=history\s*-->$')
        }
        if($isHistory){[void]$history.Append($chunk);$titles+=$title}else{[void]$essential.Append($chunk)}
    }
    @{essential=$essential.ToString();history=$history.ToString();historyTitles=$titles}
}
function Remove-SBPrivateText([string]$Text) {
    # Preserve newline positions for source citations; never return marked text in excerpts.
    [regex]::Replace($Text,'(?is)<\s*(?<tag>private|do[-_]not[-_]memorize)\b[^>]*>.*?(?:<\s*/\s*\k<tag>\s*>|\z)',
        [Text.RegularExpressions.MatchEvaluator]{param($match) [regex]::Replace($match.Value,'[^\r\n]','')})
}
# Agent view of memory.md (memory.agent.md): derived file, never edited manually. One entry per line, `- [T#id] date · scope · text`,
# where T = D decision, G gotcha, A architecture, C constraint. Includes essential parts only; free-form historical entries are classified
# by section title or prefix (Decision:/Decisione:/Gotcha:) with date `s.d.`. The header carries the source hash: -Check verifies alignment.
function Get-SBAgentViewType([string]$Heading,[string]$Text) {
    if($Text -match '^(?i)decisione?\s*:'){return 'D'}
    if($Text -match '^(?i)gotcha\s*:'){return 'G'}
    if($Heading -match '(?i)decision'){return 'D'}
    if($Heading -match '(?i)lesson|gotcha'){return 'G'}
    if($Heading -match '(?i)vincol|constraint|identit|font[ei]'){return 'C'}
    'A'
}
# Character cap of the agent view (single source). The view keeps one short line per entry: reasons ("— Motivo: …") are dropped,
# each entry is cut to $script:SBMemoryEntryCap characters, and when the cap is reached constraints and gotchas win over decisions,
# decisions over other entries; omitted entries stay complete in memory.md and are counted in the last line.
function Get-SBMemoryViewBudget { 5000 }
$script:SBMemoryEntryCap = 220
function Compress-SBAgentMemoryEntry([string]$Text) {
    $short=([regex]::Replace($Text,'\s*—\s*(?:Motivo|Reason):[^.;]*[.;]?','')).Trim()
    if($short.Length -le $script:SBMemoryEntryCap){return $short}
    $cut=$short.Substring(0,$script:SBMemoryEntryCap)
    $space=$cut.LastIndexOf(' ')
    if($space -gt $script:SBMemoryEntryCap/2){$cut=$cut.Substring(0,$space)}
    $cut.TrimEnd(' ',',',';',':')+'…'
}
function ConvertTo-SBAgentMemoryView([string]$MemoryText,[int]$Budget=(Get-SBMemoryViewBudget)) {
    $normalized=$MemoryText.Replace("`r`n","`n")
    $sourceHash=Get-SBTextHash $normalized
    $essential=Select-SBActiveDecisionText (Split-SBTieredMarkdown $normalized).essential
    $entries=[Collections.Generic.List[object]]::new();$seen=@{};$heading='';$parent='';$fence=$false
    $schema='^\[(?<t>[DGAC])\]\s+(?<d>\d{4}-\d{2}-\d{2}|s\.d\.)\s+·\s+(?<s>[^·]+?)\s+·\s+(?<x>.+)$'
    $add={
        param([string]$Raw)
        $text=([regex]::Replace(($Raw -replace '\*\*',''),'\s+',' ')).Trim()
        if(!$text -or $text -match '^(?:Original kept|Originale conservato):'){return}
        if($text -match $schema){$type=$Matches.t;$date=$Matches.d;$scope=$Matches.s.Trim();$body=$Matches.x.Trim()}
        else{$type=Get-SBAgentViewType $heading $text;$date='';$scope='';$body=$text}
        $id=(Get-SBTextHash $body).Substring(0,6).ToLowerInvariant()
        if($seen.ContainsKey($id)){return}
        $seen[$id]=$true
        $entries.Add(@{type=$type;id=$id;date=$date;scope=$scope;text=$body})
    }
    $pending=$null
    foreach($line in ($essential -split "`n")){
        if($line -match '^\s*<!-- sb:decision '){continue}
        if($line -match '^\s*(```|~~~)'){$fence=!$fence;continue}
        if($fence){continue}
        if($line -match '^(?<l>#{1,6})\s+(?<h>.+?)\s*$'){
            if($null -ne $pending){& $add $pending;$pending=$null}
            # A subsection inherits its section's kind (### Direzione under ## Decisioni correnti is a decision).
            if($Matches.l.Length -le 2){$parent=$Matches.h;$heading=$Matches.h}else{$heading=$parent+' '+$Matches.h}
            continue
        }
        if($line -match '^[-*]\s+(?<x>.*)$'){if($null -ne $pending){& $add $pending};$pending=$Matches.x;continue}
        if(!$line.Trim()){if($null -ne $pending){& $add $pending;$pending=$null};continue}
        if($null -ne $pending){$pending+=' '+$line.Trim()}else{$pending=$line.Trim()}
    }
    if($null -ne $pending){& $add $pending}
    $out=[Collections.Generic.List[string]]::new()
    $out.Add('<!-- sb:agent-view v1 source='+$sourceHash+' -->')
    $out.Add('# Memory (agent view)')
    $out.Add('')
    $out.Add('Derived from memory.md, do not edit. Entry: `[T#id] [date · scope ·] text`; T = D decision, G gotcha, A architecture, C constraint. Abbreviated entries: full text and reasons in memory.md.')
    $out.Add('')
    $lines=@(for($i=0;$i -lt $entries.Count;$i++){
        $entry=$entries[$i]
        $rank=switch($entry.type){'C'{0}'G'{1}'D'{2}default{3}}
        @{index=$i;rank=$rank;text=('- ['+$entry.type+'#'+$entry.id+'] '+$(if($entry.date){$entry.date+' · '+$entry.scope+' · '}else{''})+(Compress-SBAgentMemoryEntry $entry.text))}
    })
    $used=(($out -join "`n")+"`n").Length+120
    $kept=@{};$omitted=0
    foreach($item in ($lines|Sort-Object -Stable -Property {$_.rank})){
        if($Budget -le 0 -or $used+$item.text.Length+1 -le $Budget){$kept[$item.index]=$true;$used+=$item.text.Length+1}else{$omitted++}
    }
    foreach($item in $lines){if($kept.ContainsKey($item.index)){$out.Add($item.text)}}
    if($omitted){$out.Add('- [+'+$omitted+' entries in memory.md: knowledge.ps1 -Section "<title>" or -Search "<term>"]')}
    ($out -join "`n")+"`n"
}
function Select-SBActiveDecisionText([string]$Text) {
    $kept=@()
    foreach($chunk in (Split-SBMarkdownH2 $Text)){
        if($chunk -match '<!-- sb:decision id=[^ ]+ state=(?:superseded|expired)(?: [^>]*)? -->'){continue}
        $kept+=,$chunk
    }
    $kept -join ''
}
function Format-SBSlimTaskRow($Task) {
    $blocker=([string]$Task['blocker']) -replace '\s+',' '
    if($blocker.Length -gt 90){$blocker=$blocker.Substring(0,90).TrimEnd()+'…'}
    $title=$Task['title'] -replace '\r?\n',' '
    '- '+$Task['id']+' ['+$Task['priority']+'/'+$Task['status']+'] '+$title+$(if($blocker){' (reason: '+$blocker+')'})
}
function Format-SBSlimTasks($Projection) {
    if(!$Projection){return "No ready task.`n"}
    $rows=@($Projection|ForEach-Object {Format-SBSlimTaskRow $_})
    if(!$rows.Count){return "No ready task.`n"}
    (@(('Task ('+$rows.Count+'):'))+$rows) -join "`n"
}

function Limit-SBSlimStartup($Parts,$Projection,[string[]]$TaskIds,[int]$Budget) {
    $notice="`n"+(Get-SBMessage 'knowledge.startup.compacted')+"`n"
    $minimum=$Parts.index+$Parts.levels+$notice
    $essentialTitles=@($script:SBContextSections.english)+@($script:SBContextSections.italian)
    $requiredContext=@(Split-SBMarkdownH2 $Parts.context | Where-Object { (Get-SBMarkdownSectionTitle $_) -in $essentialTitles }) -join ''
    $requiredCharacters=$minimum.Length+$requiredContext.Length+$Parts.memory.Length+$Parts.tasks.Length
    # Essential state and selected work cannot silently disappear to make the report green.
    if($requiredCharacters -gt $Budget){return @{minimum=$requiredCharacters;omitted=@()}}
    if($minimum.Length -gt $Budget){
        $Parts.index="[index.md](index.md)`n"
        $Parts.levels=''
        $minimum=$Parts.index+$notice
    }
    if($minimum.Length -gt $Budget){
        $Parts.context='';$Parts.memory='';$Parts.tasks=''
        $Parts.levels=''
        $Parts.index=''
        return @{minimum=$minimum.Length;omitted=@()}
    }
    $remaining=$Budget-$minimum.Length
    $blocks=[Collections.Generic.List[object]]::new()
    foreach($part in @('context','memory')){
        foreach($chunk in (Split-SBMarkdownH2 $Parts[$part])){
            $title=Get-SBMarkdownSectionTitle $chunk
            $priority=4
            if($part -eq 'memory'){$priority=3}
            else{
                foreach($section in $script:SBContextSections){
                    if($title -in @($section.english,$section.italian)){$priority=$section.priority;break}
                }
            }
            $text=if($chunk.EndsWith("`n")){$chunk}else{$chunk+"`n"}
            $blocks.Add(@{part=$part;title=$title;text=$text;priority=$priority})
        }
        $Parts[$part]=''
    }
    $Parts.tasks=''
    foreach($task in $Projection){
        $blocks.Add(@{part='tasks';title=$task.id;text=(Format-SBSlimTaskRow $task)+"`n";priority=$(if($task.id -in $TaskIds){3}else{5})})
    }
    $omitted=[Collections.Generic.List[object]]::new()
    foreach($block in ($blocks | Sort-Object -Stable -Property { $_.priority })){
        if($block.text.Length -le $remaining){$Parts[$block.part]+=$block.text;$remaining-=$block.text.Length}
        else{$omitted.Add($block)}
    }
    $Parts.levels+=$notice
    $references=@(foreach($group in ($omitted | Group-Object { $_.part })){
        @{part=$group.Name;count=$group.Count;characters=($group.Group.text|Measure-Object -Property Length -Sum).Sum;
            sections=@($group.Group.title|Where-Object {$_ -and $_.Length -le 160}|Select-Object -First 12);
            how=$(if($group.Name -eq 'tasks'){'-Tasks, -Task <id> / MCP get_task'}else{'-Section <titolo> / -Startup -Profile Full'})}
    })
    @{minimum=$minimum.Length;omitted=$references}
}
function Get-SBStartupContext {
    param([string]$BrainRoot,[string]$Dossier,[string]$CheckoutPath,[string[]]$TaskIds=@(),[int]$Budget=25000,$Entities=@(),[switch]$ReadyOnly,[ValidateSet('Slim','Full')][string]$Profile='Full',[string]$PreviousRevision,[string]$DirectiveCheckout)
    if($Profile -eq 'Slim' -and !$PSBoundParameters.ContainsKey('Budget')){$Budget=Get-SBSlimStartupBudget}
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.dossier.invalid')}
    $slim=($Profile -eq 'Slim')
    $toc=Get-SBDossierTOC $Dossier $BrainRoot
    $tracker=Resolve-SBTracker -BrainRoot $BrainRoot -Identity $record.identity -CheckoutPath $CheckoutPath -DossierPath $Dossier -AllowedOwners @() -Entities $Entities
    $contextText=Read-SBText (Join-Path $Dossier 'context.md');$memoryText=Read-SBText (Join-Path $Dossier 'memory.md')
    $viewPath=Join-Path $Dossier 'memory.agent.md'
    $viewHash=if($slim -and [IO.File]::Exists($viewPath)){Get-SBFileHash $viewPath}else{''}
    $package=New-SBStartupPackage -Record $record -Tracker $tracker -TOC $toc -ContextText $contextText -MemoryText $memoryText -AgentViewHash $viewHash -TaskIds $TaskIds -Budget $Budget -ReadyOnly:$ReadyOnly -Profile $Profile
    # Revision covers source changes as well as the requested view. No client state is persisted.
    $revisionSource=[ordered]@{repository=$record.identity;profile=$Profile;budget=$Budget;readyOnly=[bool]$ReadyOnly;taskIds=@($TaskIds|Sort-Object -Unique);context=(Get-SBTextHash $contextText);memory=(Get-SBTextHash $memoryText);toc=$toc;parts=[ordered]@{}}
    foreach($key in @($package.parts.Keys|Sort-Object)){$revisionSource.parts[$key]=$package.parts[$key]}
    $package.revision=Get-SBTextHash (ConvertTo-SBJson $revisionSource)
    $package.changed=(!$PreviousRevision -or $PreviousRevision -cne $package.revision)
    $package.sourceCharacters=$package.characters
    if($slim){
        # Directive text outside the package (AGENTS.md, global instructions) counts toward the soft alert shown at session start.
        $directives=Get-SBDirectiveCharacters $DirectiveCheckout
        $package.directives=$directives
        $measured=if($package.ContainsKey('uncompactedCharacters')){$package.uncompactedCharacters}else{$package.characters}
        $package.budgetAlert=Get-SBContextBudgetAlert $measured $directives $Budget
    }
    if(!$package.changed){$package.parts=@{};$package.loadedParts=@();$package.characters=0}
    $package
}
# Compose the startup package from a resolved snapshot, without reading or writing files.
# Compaction supplies the final planned texts and agent view, before its transaction.
function New-SBStartupPackage {
    param($Record,$Tracker,[string]$TOC,[string]$ContextText,[string]$MemoryText,[string]$AgentViewHash,
        [string[]]$TaskIds=@(),[int]$Budget=25000,[switch]$ReadyOnly,[ValidateSet('Slim','Full')][string]$Profile='Full')
    $slim=($Profile -eq 'Slim')
    $trData=if($tracker.ContainsKey('graph')){$tracker.graph}elseif($tracker.ContainsKey('data')){$tracker.data}else{$null}
    $trRel=if($tracker.ContainsKey('related')){$tracker.related}else{@{}}
    $projection=if($trData -and (!$slim -or $TaskIds.Count)){@(Get-SBTaskProjection $trData $TaskIds -ReadyOnly:($ReadyOnly -or ($slim -and !$TaskIds.Count)) -RelatedTrackers $trRel)}else{@()}
    if(!$slim){
        # Full: one row per active task (id, priority/status, title, reason); details stay behind -Task <id> / MCP get_task.
        $parts=@{index=$toc;context=(Remove-SBPrivateText $contextText);memory=(Remove-SBPrivateText $memoryText);tasks=(Format-SBSlimTasks $projection)}
        $omitted=@()
    }else{
        $contextTiers=Split-SBTieredMarkdown $contextText;$memoryTiers=Split-SBTieredMarkdown $memoryText
        $omitted=@()
        foreach($entry in @(@{name='context';tiers=$contextTiers;file='context.md'},@{name='memory';tiers=$memoryTiers;file='memory.md'})){
            if($entry.tiers.history.Length){$omitted+=@{part=$entry.name+' (history)';characters=$entry.tiers.history.Length;sections=@($entry.tiers.historyTitles);how='knowledge.ps1 -Section "<title>", -Search "<term>" or -Startup -Profile Full; file '+$entry.file}}
        }
        $omitted+=@{part='tasks: descriptions, acceptance criteria, tasks not ready';characters=0;sections=@();how='knowledge.ps1 -Task <id|#seq> (full detail, archived too), -Tasks (-All for the global view), or MCP get_task and get_ready_tasks'}
        $omitted+=@{part='dossier history (history/, knowledge/, topics/)';characters=0;sections=@();how='history/index.md and the dossier index; knowledge.ps1 -Section <title> for a whole section, -Search to search the tracker archive and reports too (-Offset/-Limit)'}
        $levelLines=@('# Levels not loaded','','Slim profile: only the essential parts are loaded. Nothing was removed; ask for the rest when needed.','')
        foreach($item in $omitted){$levelLines+=('- '+$item.part+$(if($item.characters){' — '+$item.characters+' characters'}else{''})+$(if(@($item.sections).Count){' ('+(@($item.sections) -join '; ')+')'}else{''})+': '+$item.how)}
        # Memory: the agent view replaces essential memory.md parts when aligned with the source (same hash).
        $memorySlim=Select-SBActiveDecisionText $memoryTiers.essential
        if($AgentViewHash){
            $viewExpected=ConvertTo-SBAgentMemoryView $memoryText
            if($AgentViewHash -eq (Get-SBTextHash $viewExpected)){$memorySlim=$viewExpected}
        }
        $taskText=if($TaskIds.Count){Format-SBSlimTasks $projection}else{(Get-SBMessage 'knowledge.tasks.unselected')+"`n"}
        $parts=@{index=$toc;context=$contextTiers.essential;memory=$memorySlim;tasks=$taskText;levels=(($levelLines -join "`n")+"`n")}
    }
    $characters=($parts.Values|Measure-Object -Property Length -Sum).Sum
    $before=$characters;$minimum=0;$compacted=$false
    if($slim -and $Budget -gt 0 -and $before -gt $Budget){
        $selection=Limit-SBSlimStartup $parts $projection $TaskIds $Budget
        $minimum=$selection.minimum
        $compacted=$minimum -le $Budget
        if($compacted){$omitted+=@($selection.omitted)}
        $characters=($parts.Values|Measure-Object -Property Length -Sum).Sum
    }
    $fits=$Budget -le 0 -or ($characters -le $Budget -and $minimum -le $Budget)
    @{repository=$record.identity;profile=$Profile;budget=$Budget;characters=$characters;withinBudget=$fits;needsCompaction=(!$fits);compacted=$compacted;uncompactedCharacters=$before;minimumCharacters=$minimum;
      diagnostic=$(if($minimum -gt $Budget){Get-SBMessage 'knowledge.startup.minimum' @($minimum)});
      parts=$parts;loadedParts=@($parts.Keys|Sort-Object);omittedParts=@($omitted);taskSource=$tracker.path;originalsTruncated=$false;unit='characters-not-tokens'}
}
# Initial loading limit (Slim profile): single source for knowledge.ps1 -Startup and secondbrain.ps1 -Check.
function Get-SBSlimStartupBudget { 25000 }
# Characters of directive text always in context outside the startup package: the checkout's AGENTS.md and the global instructions
# of the agents that read a file (the largest counts, since a session loads one agent's file). Read-only; unreadable files count as 0.
function Get-SBDirectiveCharacters([string]$CheckoutPath) {
    $agents=0;$global=[ordered]@{}
    if($CheckoutPath){
        $file=Join-Path $CheckoutPath 'AGENTS.md'
        if(Test-Path -LiteralPath $file -PathType Leaf){try{$agents=[IO.File]::ReadAllText($file).Length}catch{[void]$_}}
    }
    foreach($name in @('Claude Code','Codex','Antigravity')){
        try{
            $path=(Get-SBIDEContext $name).instructions
            if($path -and (Test-Path -LiteralPath $path -PathType Leaf)){$global[$name]=[IO.File]::ReadAllText($path).Length}
        }catch{[void]$_}
    }
    $largest=if($global.Count){[int](($global.Values|Measure-Object -Maximum).Maximum)}else{0}
    @{agents=$agents;global=$global;globalLargest=$largest;total=($agents+$largest)}
}
# Soft/hard alert on the package plus directive text: hard only when the package itself exceeds the cap (the compactable part),
# soft once the total reaches $SoftPercent of the cap. $null when there is nothing to report.
function Get-SBContextBudgetAlert($Measured,$Directives,[int]$Budget,[int]$SoftPercent=80) {
    if($Budget -le 0){return $null}
    $directive=if($Directives){[int]$Directives.total}else{0}
    $total=[double]$Measured+$directive
    $percent=[int][Math]::Floor(100.0*$total/$Budget)
    $level=if($Measured -gt $Budget){'hard'}elseif($percent -ge $SoftPercent){'soft'}else{'none'}
    if($level -eq 'none'){return $null}
    @{level=$level;percent=$percent;budget=$Budget;packageCharacters=[int]$Measured;directiveCharacters=$directive;totalCharacters=[int]$total;message=(Get-SBMessage 'knowledge.budget.alert' @($percent,$Budget,[int]$total,[int]$Measured,$directive))}
}
# Read-only compaction advice: hard when the Slim package exceeds the limit, soft when package plus directive text is near it or when
# many turns have elapsed since the last compaction. Never compacts automatically: application remains on request (dossier.compact).
function Get-SBCompactionAdvice($Startup,[string]$BrainRoot,[string]$Dossier,[int]$SoftPercent=80,[int]$SoftTurns=50,[int]$SoftTurnsPercent=60) {
    $measured=if($Startup.ContainsKey('uncompactedCharacters')){[double]$Startup.uncompactedCharacters}else{[double]$Startup.characters}
    $directiveCharacters=if($Startup.ContainsKey('directives') -and $Startup.directives){[int]$Startup.directives.total}else{0}
    $percent=if($Startup.budget -gt 0){[int][Math]::Floor(100.0*($measured+$directiveCharacters)/$Startup.budget)}else{0}
    $last=[DateTimeOffset]::MinValue
    $manifests=Join-Path $Dossier 'history/compaction'
    if(Test-Path -LiteralPath $manifests -PathType Container){
        foreach($file in Get-ChildItem -LiteralPath $manifests -File -Filter '*.json' -Force){if([DateTimeOffset]$file.LastWriteTimeUtc -gt $last){$last=[DateTimeOffset]$file.LastWriteTimeUtc}}
    }
    $legacyTurns=Get-SBTraceTurns $BrainRoot $Startup.repository $last
    $capturedTurns=Get-SBCapturedTraceTurns $BrainRoot $Startup.repository $last
    $turns=$legacyTurns+$capturedTurns
    $level='none'
    if($Startup.budget -gt 0 -and $measured -gt $Startup.budget){$level='hard'}
    elseif($Startup.budget -gt 0 -and ($percent -ge $SoftPercent -or ($turns -ge $SoftTurns -and $percent -ge $SoftTurnsPercent))){$level='soft'}
    @{level=$level;characters=$measured;directiveCharacters=$directiveCharacters;totalCharacters=($measured+$directiveCharacters);deliveredCharacters=$Startup.characters;budget=$Startup.budget;percent=$percent;turnsSinceCompaction=$turns;legacyTurns=$legacyTurns;capturedTurns=$capturedTurns;turnCountCoverage='legacy-metadata-and-local-capture-index';lastCompactionUtc=$(if($last -eq [DateTimeOffset]::MinValue){$null}else{$last.UtcDateTime.ToString('o')})}
}
# Read-only report: characters per part, estimated tokens (characters/4, not exact), omitted parts and loaded directive sizes.
function Format-SBStartupReport($Startup,[hashtable]$Directives=@{}) {
    $lines=@('STARTUP CONTEXT REPORT','',('Repository: '+$Startup.repository),('Profile: '+$Startup.profile+' | budget '+$(if($Startup.budget -gt 0){[string]$Startup.budget+' characters'}else{'no cap'})+' | used '+$Startup.characters+' (stima ~'+[int][Math]::Ceiling($Startup.characters/4)+' tokens, characters/4)'),'')
    $lines+='Loaded parts:'
    foreach($name in ($Startup.parts.Keys|Sort-Object)){$lines+=('- {0,-8} {1,7} characters' -f $name,$Startup.parts[$name].Length)}
    if(@($Startup.omittedParts).Count){
        $lines+=@('','Parts not loaded (on request):')
        foreach($item in $Startup.omittedParts){$lines+=('- '+$item.part+$(if($item.characters){': '+$item.characters+' characters'}else{''}))}
    }
    if($Directives.Count){
        $lines+=@('','Directives always in context (outside the startup package):')
        foreach($key in ($Directives.Keys|Sort-Object)){$lines+=('- {0}: {1}' -f $key,$Directives[$key])}
    }
    if($Startup.ContainsKey('directives') -and $Startup.directives){
        # Package plus AGENTS.md plus the largest global directive: the total the soft alert measures against the cap.
        $measured=if($Startup.ContainsKey('uncompactedCharacters')){$Startup.uncompactedCharacters}else{$Startup.characters}
        $total=[int]$measured+[int]$Startup.directives.total
        $lines+=@('','Total in context at startup (package + AGENTS.md + largest global directive):',('- {0} characters (estimate ~{1} tokens, characters/4)' -f $total,[int][Math]::Ceiling($total/4)))
        if($Startup.budget -gt 0){$lines+=('- {0}% of the {1}-character cap' -f [int][Math]::Floor(100.0*$total/$Startup.budget),$Startup.budget)}
        if($Startup.budgetAlert){$lines+=@('',('WARNING: '+$Startup.budgetAlert.message))}
    }
    $lines+=@('','Not included: system prompt, MCP tools of other servers and IDE skills; see the IDE context summary.','Measured in characters, not tokens.')
    ($lines -join "`n")+"`n"
}
function Get-SBGlobalTasks([string]$BrainRoot,[string]$Repository='',[switch]$All,[switch]$ReadyOnly) {
    # Cooperative scope: without an explicit repository, the global view requires -All (read-only; each entry labeled scope=global).
    if(!$Repository -and !$All){throw (New-SBError 'knowledge.repository.required')}
    $entities=@(Get-SBParaEntities $BrainRoot @())
    $areas=@($entities|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and (!$Repository -or $_.repository -eq $Repository)})
    if($Repository -and !$areas.Count){throw (New-SBError 'knowledge.dossier.none' @($Repository))}
    $scope=if($Repository){'repository'}else{'global'}
    foreach($area in $areas){
        $dossier=Resolve-SBParaPath $BrainRoot $area.path
        try{
            $tr=Resolve-SBTracker -BrainRoot $BrainRoot -Identity $area.repository -AllowedOwners @() -DossierPath $dossier -Entities $entities
            $trData=if($tr.ContainsKey('graph')){$tr.graph}elseif($tr.ContainsKey('data')){$tr.data}else{$null}
            if(!$trData){@{repository=$area.repository;status='unverified';reasonCode='tracker-unavailable';reason=(Get-SBMessage 'knowledge.tracker.data');scope=$scope};continue}
            $rel=if($tr.ContainsKey('related') -and $tr.related){$tr.related}else{@{}}
            foreach($task in @(Get-SBTaskProjection $trData -ReadyOnly:$ReadyOnly -RelatedTrackers $rel)){
                $task.repository=$area.repository
                $task.source=$tr.path
                $task.scope=$scope
                $task
            }
        }catch{
            $diagnostic=@{repository=$area.repository;status='unverified';reason=$_.Exception.Message;scope=$scope}
            if($_.Exception.Data.Contains('code')){$diagnostic.reasonCode=$_.Exception.Data['code']}
            $diagnostic
        }
    }
}
function Get-SBGlobalTaskPage([string]$BrainRoot,[int]$Offset=0,[int]$Limit=50,[switch]$ReadyOnly) {
    # Paginated global view (same shape for CLI and MCP): Limit 0 = all entries; nextOffset identifies the next page.
    if($Offset -lt 0 -or $Limit -lt 0){throw (New-SBError 'knowledge.paging.invalid')}
    $tasks=@(Get-SBGlobalTasks -BrainRoot $BrainRoot -All -ReadyOnly:$ReadyOnly)
    $page=@($tasks|Select-Object -Skip $Offset)
    if($Limit -gt 0){$page=@($page|Select-Object -First $Limit)}
    $hasMore=($Offset+$page.Count) -lt $tasks.Count
    @{total=$tasks.Count;offset=$Offset;limit=$Limit;count=$page.Count;hasMore=$hasMore;nextOffset=$(if($hasMore){$Offset+$page.Count}else{$null});tasks=$page}
}
function Resolve-SBWorkingDossier([string]$BrainRoot,[string]$Repository) {
    # Dossier (brain-relative path) of the repository's unique active dossier.
    $found=@(Get-SBParaEntities $BrainRoot @()|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and $_.repository -ceq $Repository})
    if($found.Count -ne 1){throw (New-SBError 'knowledge.dossier.ambiguous' @($Repository))}
    $found[0].path
}
function Get-SBSearchTokens([string]$Query) {
    # Distinct case-insensitive query terms without stop words; use all terms if only stop words remain.
    $stop=@('il','lo','la','le','gli','un','una','uno','di','del','della','dei','delle','da','dal','in','nel','nella','con','su','per','tra','fra','che','the','and','for','with','from','into','of','to','an')
    $all=@([regex]::Split($Query.ToLowerInvariant(),'[^\p{L}\p{N}_-]+')|Where-Object {$_.Length -ge 2}|Select-Object -Unique)
    $kept=@($all|Where-Object {$_ -notin $stop})
    if($kept.Count){$kept}else{$all}
}
function Split-SBSearchUnits([string[]]$Lines,[bool]$Markdown) {
    # Search units: sections (heading through the next heading) for Markdown, blank-line-separated blocks (up to 40 lines) for other files.
    $units=[Collections.Generic.List[object]]::new()
    $current=@{title='';start=1;lines=[Collections.Generic.List[string]]::new()}
    $fence=$false;$number=0
    foreach($line in $Lines){
        $number++
        if($Markdown){
            if($line -match '^\s*(```|~~~)'){$fence=!$fence}
            if(!$fence -and $line -match '^#{1,6}\s+(?<title>.+?)\s*$'){
                if($current.lines.Count){$units.Add($current)}
                $current=@{title=$Matches.title;start=$number;lines=[Collections.Generic.List[string]]::new()}
            }
        }elseif(($current.lines.Count -ge 40) -or ([string]::IsNullOrWhiteSpace($line) -and $current.lines.Count)){
            $units.Add($current)
            $current=@{title='';start=$number;lines=[Collections.Generic.List[string]]::new()}
        }
        $current.lines.Add($line)
    }
    if($current.lines.Count){$units.Add($current)}
    $units
}
function Get-SBSearchDefaultLimit { 20 }
function Get-SBSearchDefaultBudget { 10000 }
function Limit-SBSearchLine([string]$Text,[int]$Max=600) {
    # Truncate long lines with a marker (read the whole line with -Section or by opening the file).
    if($Text.Length -le $Max){return $Text}
    $Text.Substring(0,$Max)+' [...+'+($Text.Length-$Max)+' car]'
}
function Get-SBKnowledgeCategory([string]$Dossier,[string]$FilePath) {
    $relative=[IO.Path]::GetRelativePath($Dossier,$FilePath).Replace([string][char]92,'/')
    if($relative -ceq 'memory.md'){return 'memoria'}
    $parts=$relative.Split('/')
    if($parts.Count -ge 3 -and $parts[0] -cin @('topics','knowledge') -and $parts[1] -cin @('normative','policy','prompt','memoria','informazioni')){return $parts[1]}
    'informazioni'
}
# Dossier directories a search covers (#466): one dossier, the dossiers of one repository, or every active repository dossier; the customer filter applies to each.
function Get-SBSearchTargetDirectories([string]$Root,[string]$Dossier,[string]$Repository,[string]$Customer,$Entities=@()) {
    if($Dossier){
        $resolved=[IO.Path]::GetFullPath($Dossier)
        if(!(Test-Path -LiteralPath $resolved)){$resolved=Resolve-SBParaPath $Root $Dossier}
        if($Customer){$recordCustomer=[string](Read-SBJson (Join-Path $resolved 'repository.json') @{}).customer;if(!(Test-SBCustomerMatch $recordCustomer $Customer)){return @()}}
        return @($resolved)
    }
    if(!$Entities.Count){$Entities=@(Get-SBParaEntities $Root @())}
    if($Repository){
        return @($Entities|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and $_.repository -eq $Repository -and (Test-SBCustomerMatch $_.customer $Customer)}|ForEach-Object {Resolve-SBParaPath $Root $_.path})
    }
    @($Entities|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and (Test-SBCustomerMatch $_.customer $Customer)}|ForEach-Object {Resolve-SBParaPath $Root $_.path})
}
# Files of one dossier a search reads, in search order (#466): current files, topics, optional compacted originals, archive and batch reports.
function Get-SBDossierSearchFiles([string]$Dir,[switch]$IncludeOriginals) {
    $files=[Collections.Generic.List[string]]::new()
    foreach($name in @('context.md','memory.md','tracker.json')){
        $candidate=Join-Path $Dir $name
        if(Test-Path -LiteralPath $candidate -PathType Leaf){$files.Add($candidate)}
    }
    foreach($name in @('topics','knowledge')){
        $topicRoot=Join-Path $Dir $name
        if(Test-Path -LiteralPath $topicRoot -PathType Container){
            Assert-SBPlainPath $topicRoot
            foreach($topicFile in Get-ChildItem -LiteralPath $topicRoot -File -Recurse -Filter '*.md'){
                Assert-SBPlainPath $topicFile.FullName;$files.Add($topicFile.FullName)
            }
        }
    }
    # Compacted originals nearly duplicate current files: search them only with -IncludeOriginals.
    $compactionDir=Join-Path $Dir 'history/compaction'
    if($IncludeOriginals -and (Test-Path -LiteralPath $compactionDir -PathType Container)){
        foreach($item in (Get-ChildItem -LiteralPath $compactionDir -File -Recurse|Sort-Object FullName)){
            if($item.Extension -in @('.md','.json','.txt')){$files.Add($item.FullName)}
        }
    }
    # Deeper layer: archived tasks and batch reports (always searchable; Offset/Limit available on request).
    $archiveFile=Join-Path $Dir 'history/tracker-archive.json'
    if(Test-Path -LiteralPath $archiveFile -PathType Leaf){$files.Add($archiveFile)}
    $historyDir=Join-Path $Dir 'history'
    if(Test-Path -LiteralPath $historyDir -PathType Container){
        foreach($folder in (Get-ChildItem -LiteralPath $historyDir -Directory|Sort-Object Name)){
            $reportFile=Join-Path $folder.FullName 'report.md'
            if(Test-Path -LiteralPath $reportFile -PathType Leaf){$files.Add($reportFile)}
        }
    }
    @($files)
}
# Relevance ranking of search units (#466): term coverage first, then title, exact phrase and capped frequency; sorted by score, path and start line.
function Get-SBRankedSearchUnits($Units,[string[]]$Tokens,[string]$Search) {
    $phrase=$Search.Trim().ToLowerInvariant()
    $ranked=@()
    foreach($unit in $Units){
        $text=($unit.lines -join "`n").ToLowerInvariant();$heading=([string]$unit.title).ToLowerInvariant()
        $distinct=0;$headingHits=0;$occurrences=0
        foreach($token in $Tokens){
            $count=([regex]::Matches($text,[regex]::Escape($token))).Count
            if($count){$distinct++;$occurrences+=$count}
            if($heading.Contains($token)){$headingHits++}
        }
        if(!$distinct){continue}
        $score=$distinct*100+$headingHits*25+$(if($text.Contains($phrase)){50}else{0})+[Math]::Min($occurrences,20)
        $ranked+=@{unit=$unit;score=$score}
    }
    @($ranked|Sort-Object @{Expression={$_.score};Descending=$true},@{Expression={$_.unit.path}},@{Expression={$_.unit.start}})
}
function Find-SBKnowledge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BrainRoot,
        [Parameter(Mandatory)][string]$Search,
        [string]$Dossier='',
        [string]$Repository='',
        # Customer filter (repository.json "customer"): restricts the search to the dossiers of that customer.
        [string]$Customer='',
        # -1 = default (Get-SBSearchDefaultLimit / Get-SBSearchDefaultBudget); 0 = explicitly unlimited.
        [ValidateRange(-1,[int]::MaxValue)][int]$Budget=-1,
        $Entities=@(),
        [ValidateSet('Literal','Relevance')][string]$Mode='Literal',
        [ValidateRange(0,[int]::MaxValue)][int]$Offset=0,
        [ValidateRange(-1,[int]::MaxValue)][int]$Limit=-1,
        [switch]$IncludeOriginals,
        # Index by category: memoria (memory.md), informazioni (context, tracker, reports), normative/policy (topics|knowledge/<category>/), prompt (directives/prompts, only when requested).
        [ValidateSet('normative','policy','informazioni','prompt','memoria')][string[]]$Category=@(),
        # Revision returned by a previous identical search: when nothing searched changed, no extract is repeated.
        [string]$PreviousRevision=''
    )
    if($Budget -lt 0){$Budget=Get-SBSearchDefaultBudget}
    if($Limit -lt 0){$Limit=Get-SBSearchDefaultLimit}
    $root=[IO.Path]::GetFullPath($BrainRoot)
    $targetDirs=@(Get-SBSearchTargetDirectories $root $Dossier $Repository $Customer $Entities)
    $extracts=[Collections.Generic.List[object]]::new()
    $candidates=[Collections.Generic.List[object]]::new()
    $totalChars=0
    if([string]::IsNullOrWhiteSpace($Search)){
        return @{search=$Search;query=$Search;mode=$Mode;budget=$Budget;offset=$Offset;limit=$Limit;hasMore=$false;nextOffset=$null;characters=0;withinBudget=$true;totalMatches=0;count=0;extracts=@()}
    }
    $tokens=@();$rankUnits=[Collections.Generic.List[object]]::new()
    if($Mode -eq 'Relevance'){$tokens=@(Get-SBSearchTokens $Search)}
    $revisionParts=[Collections.Generic.List[string]]::new()
    $processFile={
        param($filePath,$dir,$searchRepository,$fileCategory)
        if($Category.Count -and $fileCategory -notin $Category){return}
        $hash=Get-SBFileHash $filePath
        $relPath=[IO.Path]::GetRelativePath($root,$filePath).Replace('\','/')
        $revisionParts.Add($relPath+':'+$hash)
        $documentId=(Get-SBTextHash ($searchRepository+':'+[IO.Path]::GetRelativePath($dir,$filePath).Replace('\','/'))).ToLowerInvariant()
        $lines=(Remove-SBPrivateText (Read-SBText $filePath)) -split '\r?\n'
        if($Mode -eq 'Relevance'){
            foreach($unit in @(Split-SBSearchUnits $lines ($filePath -like '*.md'))){$unit.path=$relPath;$unit.sha256=$hash;$unit.documentId=$documentId;$unit.repository=$searchRepository;$unit.category=$fileCategory;$rankUnits.Add($unit)}
            return
        }
        $lineNum=0
        foreach($line in $lines){
            $lineNum++
            if($line.Contains($Search,[StringComparison]::OrdinalIgnoreCase)){
                $trimmed=Limit-SBSearchLine $line.Trim()
                $candidates.Add(@{extract=@{documentId=$documentId;repository=$searchRepository;path=$relPath;line=$lineNum;sha256=$hash;category=$fileCategory;text=$trimmed};size=($relPath.Length + $trimmed.Length + $hash.Length + 20)})
            }
        }
        }
    foreach($dir in $targetDirs){
        if(!(Test-Path -LiteralPath $dir -PathType Container)){continue}
        $searchRepository=[string](Read-SBJson (Join-Path $dir 'repository.json') @{}).identity
        $filesToSearch=@(Get-SBDossierSearchFiles $dir -IncludeOriginals:$IncludeOriginals)
        foreach($filePath in $filesToSearch){& $processFile $filePath $dir $searchRepository (Get-SBKnowledgeCategory $dir $filePath)}
    }
    if('prompt' -in $Category){
        $promptDir=Join-Path $root 'directives/prompts'
        if(Test-Path -LiteralPath $promptDir -PathType Container){
            Assert-SBPlainPath $promptDir
            foreach($promptFile in (Get-ChildItem -LiteralPath $promptDir -File -Filter '*.md'|Where-Object Name -ne 'README.md'|Sort-Object Name)){& $processFile $promptFile.FullName $root '' 'prompt'}
        }
    }
    $ranked=@()
    if($Mode -eq 'Relevance'){
        $ranked=@(Get-SBRankedSearchUnits $rankUnits $tokens $Search)
        foreach($entry in $ranked){
            $unit=$entry.unit;$lineNum=$unit.start-1
            foreach($line in $unit.lines){
                $lineNum++
                $lower=$line.ToLowerInvariant()
                if(!@($tokens|Where-Object {$lower.Contains($_)}).Count){continue}
                $trimmed=Limit-SBSearchLine $line.Trim()
                $candidates.Add(@{extract=@{documentId=$unit.documentId;repository=$unit.repository;path=$unit.path;line=$lineNum;sha256=$unit.sha256;category=$unit.category;text=$trimmed;score=$entry.score;section=[string]$unit.title};size=($unit.path.Length + $trimmed.Length + $unit.sha256.Length + 20)})
            }
        }
    }
    # Page the sorted matches, then apply the optional character limit to that page.
    $totalMatches=$candidates.Count
    $page=@($candidates|Select-Object -Skip $Offset)
    if($Limit -gt 0){$page=@($page|Select-Object -First $Limit)}
    # The character limit stops at the first overflowing match (always include at least one): the page stays contiguous and nextOffset resumes there.
    foreach($candidate in $page){
        if($Budget -gt 0 -and $extracts.Count -gt 0 -and $totalChars + $candidate.size -gt $Budget){break}
        $extracts.Add($candidate.extract)
        $totalChars += $candidate.size
    }
    $withinBudget=($page.Count -eq $extracts.Count)
    $hasMore=(($Offset + $extracts.Count) -lt $totalMatches)
    # The revision covers query, mode, categories and every searched file hash: unchanged input means nothing new to repeat.
    $revision=(Get-SBTextHash ($Mode+"`n"+$Search+"`n"+(@($Category|Sort-Object) -join ',')+"`n"+[string][bool]$IncludeOriginals+"`n"+($revisionParts -join "`n"))).ToLowerInvariant()
    if($PreviousRevision -and $Offset -eq 0 -and $PreviousRevision -ceq $revision){
        return @{search=$Search;query=$Search;mode=$Mode;category=@($Category);revision=$revision;unchanged=$true;budget=$Budget;characters=0;withinBudget=$true;offset=$Offset;limit=$Limit;hasMore=$false;nextOffset=$null;totalMatches=$totalMatches;count=0;extracts=@()}
    }
    @{
        search=$Search
        category=@($Category)
        revision=$revision
        unchanged=$false
        query=$Search
        mode=$Mode
        tokens=@($tokens)
        units=@($ranked).Count
        budget=$Budget
        characters=$totalChars
        withinBudget=$withinBudget
        offset=$Offset
        limit=$Limit
        hasMore=$hasMore
        nextOffset=$(if($hasMore){$Offset + $extracts.Count}else{$null})
        totalMatches=$totalMatches
        count=$extracts.Count
        extracts=@($extracts)
    }
}
# Repository lifecycle in the dossier's repository.json: absent (normal) or greenfield (guard for versions, changelog, migrations, aliases and deprecations).
function Get-SBRepositoryLifecycle([string]$Dossier) {
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record -or !$record.ContainsKey('lifecycle')){return ''}
    if([string]$record.lifecycle -cne 'greenfield'){throw (New-SBError 'knowledge.lifecycle.invalid')}
    'greenfield'
}
function Set-SBRepositoryCustomer {
    # Customer / company of the repository, recorded in the dossier's repository.json (roadmap and reports read it).
    param([Parameter(Mandatory)][string]$Dossier,[Parameter(Mandatory)][string]$Customer,[Parameter(Mandatory)][string]$BackupRoot)
    $path=Join-Path $Dossier 'repository.json'
    $record=Read-SBJson $path $null
    if(!$record){throw (New-SBError 'knowledge.record.missing')}
    $value=$Customer.Trim()
    $changed=(!$record.ContainsKey('customer') -or [string]$record.customer -cne $value)
    if($changed){$record.customer=$value;[void](Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))) (Get-SBFileHash $path) $BackupRoot)}
    @{repository=$record.identity;customer=$value;changed=$changed}
}
function Set-SBRepositoryLifecycle {
    param([Parameter(Mandatory)][string]$Dossier,[Parameter(Mandatory)][ValidateSet('greenfield','none')][string]$Lifecycle,[Parameter(Mandatory)][string]$BackupRoot)
    $path=Join-Path $Dossier 'repository.json'
    $record=Read-SBJson $path $null
    if(!$record){throw (New-SBError 'knowledge.record.missing')}
    $before=$(if($record.ContainsKey('lifecycle')){[string]$record.lifecycle}else{''})
    if($Lifecycle -eq 'greenfield'){$record.lifecycle='greenfield'}else{[void]$record.Remove('lifecycle')}
    $changed=($before -ne $(if($Lifecycle -eq 'greenfield'){'greenfield'}else{''}))
    if($changed){[void](Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))) (Get-SBFileHash $path) $BackupRoot)}
    @{repository=$record.identity;lifecycle=$(if($Lifecycle -eq 'greenfield'){'greenfield'}else{''});changed=$changed}
}
function Get-SBTaskDetail {
    # Complete task details by ID or seq (including "#203"), from the active tracker or dossier archive.
    param([Parameter(Mandatory)][string]$BrainRoot,[Parameter(Mandatory)][string]$Dossier,[Parameter(Mandatory)][string]$Task,[string]$CheckoutPath)
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.dossier.invalid')}
    $tracker=Resolve-SBTracker -BrainRoot $BrainRoot -Identity $record.identity -CheckoutPath $CheckoutPath -DossierPath $Dossier -AllowedOwners @()
    if(!$tracker.ContainsKey('data') -or !$tracker.data){throw (New-SBError 'knowledge.tracker.unavailable')}
    $key=$Task.Trim();$seq=0
    $bySeq=($key -match '^#?\d+$') -and [int]::TryParse($key.TrimStart('#'),[ref]$seq)
    $sources=@(@{name='tracker';tasks=@($tracker.data.tasks);path=[string]$tracker.path})
    $archivePath=Join-Path $Dossier 'history/tracker-archive.json'
    $archive=$tracker.archive.data
    if($archive -and $archive.ContainsKey('tasks')){$sources+=@{name='archive';tasks=@($archive.tasks);path=$archivePath}}
    foreach($source in $sources){
        $found=@($source.tasks|Where-Object {if($bySeq){$_.ContainsKey('seq') -and [int]$_.seq -eq $seq}else{[string]$_.id -ieq $key}})
        if($found.Count -gt 1){throw (New-SBError 'knowledge.task.ambiguous' @($Task))}
        if($found.Count){return @{repository=$record.identity;source=$source.name;path=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($BrainRoot),$source.path).Replace('\','/');task=$found[0]}}
    }
    throw (New-SBError 'knowledge.task.notfound' @($Task))
}
function Get-SBRoadmap {
    # Roadmap of the interventions of ONE repository: tracker/archive history (date from the history folder, tasks, commit and PR mentions) plus the checkout's git log.
    param([Parameter(Mandatory)][string]$BrainRoot,[Parameter(Mandatory)][string]$Dossier,[string]$CheckoutPath,[string]$Since,[ValidateRange(0,5000)][int]$MaxCommits=200)
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.dossier.invalid')}
    $relativeDossier=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($BrainRoot),[IO.Path]::GetFullPath($Dossier)).Replace('\','/')
    $tracker=Resolve-SBTracker -BrainRoot $BrainRoot -Identity $record.identity -CheckoutPath $CheckoutPath -DossierPath $relativeDossier -AllowedOwners @()
    if(!$tracker.ContainsKey('data') -or !$tracker.data){throw (New-SBError 'knowledge.tracker.unavailable')}
    $history=@($tracker.data.history)
    $archive=$tracker.archive.data
    if($archive -and $archive.ContainsKey('history')){$history=@($archive.history)+$history}
    $commits=@()
    if($CheckoutPath -and $MaxCommits -gt 0 -and (Test-Path -LiteralPath (Join-Path $CheckoutPath '.git'))){
        $log=Invoke-SBGit $CheckoutPath @('log','--no-color','--date=short',('--max-count='+$MaxCommits),'--pretty=format:%h%x09%ad%x09%an%x09%s')
        if($log.code -eq 0 -and $log.output){$commits=@($log.output -split '\r?\n'|Where-Object {$_}|ForEach-Object {$p=$_ -split "`t",4;if($p.Count -eq 4){@{hash=$p[0];date=$p[1];author=$p[2];subject=$p[3]}}})}
    }
    $position=0
    $interventions=@(foreach($entry in $history){
        $position++;$text=[string]$entry.description;$reference=[string]$entry.reference
        $date=if($reference -match '(\d{4}-\d{2}-\d{2})'){$Matches[1]}elseif($text -match '(\d{4}-\d{2}-\d{2})'){$Matches[1]}else{''}
        $tasks=@([regex]::Matches(($text -replace 'PR\s*#\d+',''),'#\d+')|ForEach-Object {$_.Value}|Select-Object -Unique)
        $shas=@([regex]::Matches($text,'(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])')|ForEach-Object {$_.Value}|Where-Object {$_ -match '[a-f]' -and $_ -match '\d'}|Select-Object -Unique)
        $prs=@([regex]::Matches($text,'(?:PR\s*#|pull/)(\d+)')|ForEach-Object {'#'+$_.Groups[1].Value}|Select-Object -Unique)
        [ordered]@{order=$position;date=$date;tasks=$tasks;description=$text;reference=$reference;commits=$shas;pullRequests=$prs}
    })
    if($Since){$interventions=@($interventions|Where-Object {!$_.date -or $_.date -ge $Since});$commits=@($commits|Where-Object {$_.date -ge $Since})}
    $interventions=@($interventions|Sort-Object {if($_.date){$_.date}else{'9999-99-99'}},{$_.order})
    # Done tasks move to the archive on every save: count them across the active tracker and the archive.
    $done=@(@($tracker.data.tasks)+@($(if($archive){$archive.tasks}))|Where-Object {$_ -and $_.status -eq 'done'}|ForEach-Object {@{id=[string]$_.id;title=[string]$_.title}})
    [ordered]@{repository=[string]$record.identity;customer=$(if($record.ContainsKey('customer')){[string]$record.customer}else{''});interventions=$interventions;commits=$commits;completedTasks=$done.Count}
}
function ConvertTo-SBRoadmapMarkdown($Roadmap) {
    $cell={param($v) ([string]$v).Replace('|','\|').Replace("`r",' ').Replace("`n",' ')}
    $lines=@("# Roadmap: $($Roadmap.repository)")
    if($Roadmap.customer){$lines+=@('','Cliente / azienda: '+$Roadmap.customer)}
    $lines+=@('','## Interventi','','| Data | Task | Intervento | Commit / PR | Riferimento |','|---|---|---|---|---|')
    foreach($i in $Roadmap.interventions){$lines+=('| '+(& $cell $i.date)+' | '+(& $cell ($i.tasks -join ', '))+' | '+(& $cell $i.description)+' | '+(& $cell ((@($i.commits)+@($i.pullRequests)) -join ', '))+' | '+(& $cell $i.reference)+' |')}
    if(@($Roadmap.commits).Count){
        $lines+=@('','## Commit del repository','','| Data | Commit | Autore | Oggetto |','|---|---|---|---|')
        foreach($c in $Roadmap.commits){$lines+=('| '+$c.date+' | '+$c.hash+' | '+(& $cell $c.author)+' | '+(& $cell $c.subject)+' |')}
    }
    ($lines -join "`n")+"`n"
}
function Get-SBMarkdownSections([string[]]$Lines) {
    # Markdown sections: any heading through the next heading at the same or a higher level (including subsections); ignore code fences.
    $headings=@();$fence=$false;$number=0
    foreach($line in $Lines){
        $number++
        if($line -match '^\s*(```|~~~)'){$fence=!$fence;continue}
        if(!$fence -and $line -match '^(?<marks>#{1,6})\s+(?<title>.+?)\s*$'){$headings+=@{title=$Matches.title;level=$Matches.marks.Length;start=$number;end=$Lines.Count}}
    }
    for($i=0;$i -lt $headings.Count;$i++){
        for($j=$i+1;$j -lt $headings.Count;$j++){if($headings[$j].level -le $headings[$i].level){$headings[$i].end=$headings[$j].start-1;break}}
    }
    $headings
}
function Get-SBSection {
    # Whole named section from context.md, memory.md and history/*/report.md (Source: context, memory, history, history/<folder>).
    param([Parameter(Mandatory)][string]$BrainRoot,[Parameter(Mandatory)][string]$Dossier,[Parameter(Mandatory)][string]$Title,[string]$Source='')
    $root=[IO.Path]::GetFullPath($BrainRoot)
    $record=Read-SBJson (Join-Path $Dossier 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.dossier.invalid')}
    $files=@()
    $wanted=$Source.Trim().Trim('/').ToLowerInvariant()
    if($wanted -and $wanted -notmatch '^(context|memory|history(/[^/\\]+)?)$'){throw (New-SBError 'knowledge.source.invalid')}
    if(!$wanted -or $wanted -eq 'context'){$files+=Join-Path $Dossier 'context.md'}
    if(!$wanted -or $wanted -eq 'memory'){$files+=Join-Path $Dossier 'memory.md'}
    if(!$wanted -or $wanted -eq 'history'){
        $historyDir=Join-Path $Dossier 'history'
        if(Test-Path -LiteralPath $historyDir -PathType Container){foreach($folder in Get-ChildItem -LiteralPath $historyDir -Directory|Sort-Object Name){$files+=Join-Path $folder.FullName 'report.md'}}
    }elseif($wanted -like 'history/*'){$files+=Join-Path $Dossier ($wanted+'/report.md')}
    $wantedTitle=$Title.Trim()
    $exact=@();$partial=@()
    foreach($file in $files){
        if(!(Test-Path -LiteralPath $file -PathType Leaf)){continue}
        $lines=(Remove-SBPrivateText (Read-SBText $file)) -split '\r?\n'
        $hash=Get-SBFileHash $file
        foreach($section in @(Get-SBMarkdownSections $lines)){
            $hit=@{path=[IO.Path]::GetRelativePath($root,$file).Replace('\','/');sha256=$hash;title=$section.title;level=$section.level;line=$section.start;endLine=$section.end;lines=$lines}
            if($section.title -ieq $wantedTitle){$exact+=$hit}elseif($section.title.Contains($wantedTitle,[StringComparison]::OrdinalIgnoreCase)){$partial+=$hit}
        }
    }
    $hits=if($exact.Count){$exact}else{$partial}
    if(!$hits.Count){throw (New-SBError 'knowledge.section.notfound' @($Title))}
    $found=@($hits|ForEach-Object {
        $text=(($_.lines[($_.line-1)..($_.endLine-1)]) -join "`n").TrimEnd()
        @{path=$_.path;sha256=$_.sha256;title=$_.title;level=$_.level;line=$_.line;endLine=$_.endLine;characters=$text.Length;text=$text}
    })
    @{repository=$record.identity;section=$Title;matchKind=$(if($exact.Count){'exact'}else{'partial'});count=$found.Count;matches=$found}
}
function Invoke-SBDossierCompaction {
    param([string]$BrainRoot,[string]$Dossier,[string]$CandidatePath,[string]$BackupRoot,[switch]$Apply,[string]$CheckoutPath,[int]$Budget=(Get-SBSlimStartupBudget))
    if([string]::IsNullOrWhiteSpace($Dossier)){throw (New-SBError 'knowledge.dossier.unspecified')}
    $root=[IO.Path]::GetFullPath($BrainRoot);$dir=[IO.Path]::GetFullPath($Dossier)
    [void](Assert-SBPlainPath $dir)
    $relative=[IO.Path]::GetRelativePath($root,$dir).Replace('\','/');[void](Resolve-SBParaPath $root $relative)
    if(@(Read-SBJson (Join-Path $dir 'entity.json') @{}).status -notin @($null,'active')){throw (New-SBError 'knowledge.dossier.archived')}
    $candidate=Read-SBJson (Assert-SBCentralDataPath $root $CandidatePath) $null
    if(!$candidate -or $candidate.schemaVersion -ne 1 -or $candidate.reviewed -ne $true -or !$candidate.reviewNote){throw (New-SBError 'knowledge.candidate.review')}
    $record=Read-SBJson (Join-Path $dir 'repository.json') $null
    if($candidate.repository -cne $record.identity){throw (New-SBError 'knowledge.candidate.repository')}
    $ops=@();$archives=@();$planned=@{}
    $attributesPath=Join-Path $dir 'history/compaction/.gitattributes'
    if((Get-SBFileHash $attributesPath) -eq 'absent'){$ops+=@{path=$attributesPath;expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes("* -text -whitespace`n")}}
    foreach($name in @('context.md','memory.md')){
        $source=Join-Path $dir $name;$hash=Get-SBFileHash $source
        if(!$candidate.sources.ContainsKey($name) -or $candidate.sources[$name] -ne $hash){throw (New-SBError 'knowledge.source.changed' @($name))}
        if(!$candidate.summaries.ContainsKey($name) -or !$candidate.summaries[$name].Trim()){throw (New-SBError 'knowledge.summary.missing' @($name))}
        $text=[string]$candidate.summaries[$name]
        if($name -eq 'context.md'){
            foreach($heading in (Get-SBMissingContextSection $text)){
                throw (New-SBError 'knowledge.section.essential' @($heading))
            }
        }
        $archiveRelative='history/compaction/'+$hash.ToLowerInvariant()+'/'+$name
        $archive=Join-Path $dir $archiveRelative;$existing=Get-SBFileHash $archive
        if($existing -eq 'absent'){$ops+=@{path=$archive;expected='absent';bytes=[IO.File]::ReadAllBytes($source)}}elseif($existing -ne $hash){throw (New-SBError 'knowledge.original.diverged')}
        $text=$text.TrimEnd()+"`n`nOriginal kept: ["+$name+']('+$archiveRelative+"). Historical authorizations are not current authorizations.`n"
        $planned[$name]=$text
        $ops+=@{path=$source;expected=$hash;bytes=[Text.Encoding]::UTF8.GetBytes($text)}
        if($name -eq 'memory.md'){
            # The agent view follows the new memory in the same transaction.
            $viewPath=Join-Path $dir 'memory.agent.md'
            $planned['memory.agent.md']=ConvertTo-SBAgentMemoryView $text
            $ops+=@{path=$viewPath;expected=(Get-SBFileHash $viewPath);bytes=[Text.Encoding]::UTF8.GetBytes($planned['memory.agent.md'])}
        }
        $archives+=@{source=$name;sha256=$hash;archive=$archiveRelative}
    }
    $tracker=Resolve-SBTracker -BrainRoot $root -Identity $record.identity -DossierPath $dir -CheckoutPath $CheckoutPath -AllowedOwners @()
    $openIds=@($tracker.data.tasks|Where-Object status -notin @('done','cancelled')|ForEach-Object id)
    if(@($openIds|Where-Object {$_ -notin $candidate.openTaskIds}).Count){throw (New-SBError 'knowledge.candidate.tasks')}
    $toc=Get-SBDossierTOC $dir $root;$index=Join-Path $dir 'index.md'
    $ops+=@{path=$index;expected=(Get-SBFileHash $index);bytes=[Text.Encoding]::UTF8.GetBytes($toc)}
    # Measure exactly the Slim package that startup will load after this transaction.
    $startup=New-SBStartupPackage -Record $record -Tracker $tracker -TOC $toc -ContextText $planned['context.md'] -MemoryText $planned['memory.md'] -AgentViewHash (Get-SBTextHash $planned['memory.agent.md']) -Profile Slim -Budget $Budget
    if($Budget -gt 0 -and $startup.uncompactedCharacters -gt $Budget){throw (New-SBError 'knowledge.budget.exceeded')}
    $manifest=@{schemaVersion=1;repository=$record.identity;archives=$archives;reviewNote=$candidate.reviewNote;openTaskIds=$openIds;candidateSha256=(Get-SBFileHash $CandidatePath)}
    $manifestPath=Join-Path $dir ('history/compaction/'+(Get-SBFileHash $CandidatePath).ToLowerInvariant()+'.json')
    $manifestText=ConvertTo-SBJson $manifest
    if((Get-SBFileHash $manifestPath) -eq 'absent'){$ops+=@{path=$manifestPath;expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes($manifestText)}}
    if($Apply){[void](Assert-SBCentralDataPath $root $BackupRoot);Invoke-SBParaTransaction $ops $BackupRoot $root|Out-Null}
    @{repository=$record.identity;applied=[bool]$Apply;archives=$archives;operations=$ops.Count;originalsPreserved=$true;manifest=$manifestPath}
}
# Mechanical, lossless tiering (no model): when the startup context (Slim package plus directive text) reaches TriggerPercent of the budget,
# the oldest dated `## ` sections of context.md and memory.md are marked <!-- sb:tier=history --> until the total falls to TargetPercent.
# Nothing is rewritten or deleted: marked sections stay in the files and are retrievable with -Section / -Search. A section is eligible only
# when its newest ISO date (yyyy-MM-dd) is older than OlderThanDays; undated sections, the required context sections, sections that are
# already history and sections holding an active sb:decision marker are never touched. Originals are archived by hash like -Compact,
# memory.agent.md and index.md are regenerated in the same transaction. Without -Apply it only previews.
function Invoke-SBMechanicalTiering {
    param([string]$BrainRoot,[string]$Dossier,[string]$BackupRoot,[switch]$Apply,[string]$CheckoutPath,[int]$Budget=(Get-SBSlimStartupBudget),
        [ValidateRange(1,100)][int]$TargetPercent=70,[ValidateRange(0,100)][int]$TriggerPercent=0,[ValidateRange(0,3650)][int]$OlderThanDays=30)
    if([string]::IsNullOrWhiteSpace($Dossier)){throw (New-SBError 'knowledge.dossier.unspecified')}
    $root=[IO.Path]::GetFullPath($BrainRoot);$dir=[IO.Path]::GetFullPath($Dossier)
    [void](Assert-SBPlainPath $dir)
    $relative=[IO.Path]::GetRelativePath($root,$dir).Replace('\','/');[void](Resolve-SBParaPath $root $relative)
    if(@(Read-SBJson (Join-Path $dir 'entity.json') @{}).status -notin @($null,'active')){throw (New-SBError 'knowledge.dossier.archived')}
    $record=Read-SBJson (Join-Path $dir 'repository.json') $null
    if(!$record){throw (New-SBError 'knowledge.record.missing')}
    $tracker=Resolve-SBTracker -BrainRoot $root -Identity $record.identity -DossierPath $dir -CheckoutPath $CheckoutPath -AllowedOwners @()
    $toc=Get-SBDossierTOC $dir $root
    $directive=[int](Get-SBDirectiveCharacters $CheckoutPath).total
    $measure={
        param([string]$Context,[string]$Memory)
        $view=ConvertTo-SBAgentMemoryView $Memory
        [int](New-SBStartupPackage -Record $record -Tracker $tracker -TOC $toc -ContextText $Context -MemoryText $Memory -AgentViewHash (Get-SBTextHash $view) -Profile Slim -Budget 0).uncompactedCharacters
    }
    $sources=[ordered]@{};$eol=@{}
    foreach($name in @('context.md','memory.md')){
        $text=Read-SBText (Join-Path $dir $name)
        $eol[$name]=$text.Contains("`r`n")
        $sources[$name]=$text.Replace("`r`n","`n")
    }
    $before=(& $measure $sources['context.md'] $sources['memory.md'])+$directive
    $target=[int][Math]::Floor($Budget*$TargetPercent/100.0)
    $result=@{repository=$record.identity;applied=$false;action='none';budget=$Budget;targetCharacters=$target;triggerPercent=$TriggerPercent;beforeCharacters=$before;afterCharacters=$before;demoted=@();operations=0;originalsPreserved=$true;unit='characters-not-tokens'}
    if($Budget -le 0 -or $before -le $target -or (100.0*$before/$Budget) -lt $TriggerPercent){return $result}
    $cutoff=(Get-SBNow).AddDays(-$OlderThanDays)
    $required=@($script:SBContextSections.english)+@($script:SBContextSections.italian)
    $candidates=@()
    foreach($name in $sources.Keys){
        $chunks=@(Split-SBMarkdownH2 $sources[$name])
        for($i=0;$i -lt $chunks.Count;$i++){
            $chunk=$chunks[$i]
            if(!$chunk.StartsWith('## ')){continue}
            $title=Get-SBMarkdownSectionTitle $chunk
            if($name -eq 'context.md' -and $title -in $required){continue}
            if((Split-SBTieredMarkdown $chunk).essential.Length -eq 0){continue}
            if($chunk -match '<!-- sb:decision id=[^ ]+ state=(?!superseded|expired)'){continue}
            $newest=$null
            foreach($m in [regex]::Matches($chunk,'\b20\d{2}-\d{2}-\d{2}\b')){
                $parsed=[datetime]::MinValue
                if([datetime]::TryParseExact($m.Value,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,[ref]$parsed) -and (!$newest -or $parsed -gt $newest)){$newest=$parsed}
            }
            if(!$newest -or $newest -ge $cutoff.UtcDateTime){continue}
            $candidates+=,@{file=$name;index=$i;title=$title;newest=$newest;characters=$chunk.Length}
        }
    }
    $planned=@{}
    foreach($name in $sources.Keys){$planned[$name]=@(Split-SBMarkdownH2 $sources[$name])}
    $demoted=@();$after=$before
    foreach($candidate in @($candidates|Sort-Object @{Expression={$_.newest}},@{Expression={$_.file}},@{Expression={$_.index}})){
        if($after -le $target){break}
        $lines=$planned[$candidate.file][$candidate.index] -split "`n",2
        $planned[$candidate.file][$candidate.index]=$lines[0]+"`n<!-- sb:tier=history -->`n"+$(if($lines.Count -gt 1){$lines[1]}else{''})
        $after=(& $measure (($planned['context.md']) -join '') (($planned['memory.md']) -join ''))+$directive
        $demoted+=@{file=$candidate.file;title=$candidate.title;newestDate=$candidate.newest.ToString('yyyy-MM-dd');characters=$candidate.characters}
    }
    if(!$demoted.Count){$result.action='no-eligible';return $result}
    $result.action='tiered';$result.demoted=@($demoted);$result.afterCharacters=$after
    $ops=@();$archives=@();$newText=@{}
    $attributesPath=Join-Path $dir 'history/compaction/.gitattributes'
    if((Get-SBFileHash $attributesPath) -eq 'absent'){$ops+=@{path=$attributesPath;expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes("* -text -whitespace`n")}}
    foreach($name in @($demoted|ForEach-Object file|Select-Object -Unique)){
        $source=Join-Path $dir $name;$hash=Get-SBFileHash $source
        $text=($planned[$name]) -join ''
        if($eol[$name]){$text=$text.Replace("`n","`r`n")}
        $newText[$name]=$text
        $archiveRelative='history/compaction/'+$hash.ToLowerInvariant()+'/'+$name
        $archive=Join-Path $dir $archiveRelative;$existing=Get-SBFileHash $archive
        if($existing -eq 'absent'){$ops+=@{path=$archive;expected='absent';bytes=[IO.File]::ReadAllBytes($source)}}elseif($existing -ne $hash){throw (New-SBError 'knowledge.original.diverged')}
        $ops+=@{path=$source;expected=$hash;bytes=[Text.Encoding]::UTF8.GetBytes($text)}
        $archives+=@{source=$name;sha256=$hash;archive=$archiveRelative}
    }
    $memoryAfter=if($newText.ContainsKey('memory.md')){$newText['memory.md']}else{$sources['memory.md']}
    if($newText.ContainsKey('memory.md')){
        $viewPath=Join-Path $dir 'memory.agent.md'
        $ops+=@{path=$viewPath;expected=(Get-SBFileHash $viewPath);bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBAgentMemoryView $memoryAfter))}
    }
    $index=Join-Path $dir 'index.md'
    $ops+=@{path=$index;expected=(Get-SBFileHash $index);bytes=[Text.Encoding]::UTF8.GetBytes($toc)}
    $manifest=@{schemaVersion=1;mode='mechanical';repository=$record.identity;archives=$archives;demoted=@($demoted);olderThanDays=$OlderThanDays;targetPercent=$TargetPercent;beforeCharacters=$before;afterCharacters=$after;at=(Get-SBNow).ToString('o')}
    $manifestText=ConvertTo-SBJson $manifest
    $manifestPath=Join-Path $dir ('history/compaction/mechanical-'+(Get-SBTextHash $manifestText).Substring(0,16).ToLowerInvariant()+'.json')
    if((Get-SBFileHash $manifestPath) -eq 'absent'){$ops+=@{path=$manifestPath;expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes($manifestText)}}
    if($Apply){[void](Assert-SBCentralDataPath $root $BackupRoot);Invoke-SBParaTransaction $ops $BackupRoot $root|Out-Null;$result.applied=$true}
    $result.operations=$ops.Count;$result.archives=$archives;$result.manifest=$manifestPath
    $result
}
Export-ModuleMember -Function @(
    'Get-SBSearchTargetDirectories',
    'Get-SBDossierSearchFiles',
    'Get-SBRankedSearchUnits',
    'Get-SBRoadmap',
    'ConvertTo-SBRoadmapMarkdown',
    'Remove-SBPrivateText',
    'Get-SBDossierTOC',
    'Get-SBMissingContextSection',
    'Get-SBDossierHistoryIndex',
    'Get-SBTaskProjection',
    'Split-SBTieredMarkdown',
    'ConvertTo-SBAgentMemoryView',
    'Get-SBStartupContext',
    'Get-SBSlimStartupBudget',
    'Get-SBMemoryViewBudget',
    'Get-SBCompactionAdvice',
    'Get-SBDirectiveCharacters',
    'Get-SBContextBudgetAlert',
    'Format-SBStartupReport',
    'Get-SBGlobalTasks',
    'Get-SBGlobalTaskPage',
    'Resolve-SBWorkingDossier',
    'Find-SBKnowledge',
    'Get-SBSearchDefaultLimit',
    'Get-SBSearchDefaultBudget',
    'Get-SBRepositoryLifecycle',
    'Set-SBRepositoryLifecycle',
    'Set-SBRepositoryCustomer',
    'Get-SBTaskDetail',
    'Get-SBSection',
    'Invoke-SBDossierCompaction',
    'Invoke-SBMechanicalTiering'
)
