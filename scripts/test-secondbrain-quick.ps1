#requires -Version 7.5
# Pure source checks: no Git or child processes.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Force
$script:quickChecks=0
function Assert-Quick($Condition,[string]$Message){if(!$Condition){throw 'FAIL QUICK: '+$Message};$script:quickChecks++;'PASS QUICK: '+$Message}
$productRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
try {
    # Repository identities. The '@' is composed at runtime so that no email-shaped literal appears in the source.
    $at='@'
    Assert-Quick ((ConvertTo-SBRepositoryIdentity "git${at}gitlab.example:group/nested/repo.git") -eq 'gitlab.example/group/nested/repo') 'nested GitLab without an owner constraint'
    Assert-Quick ((ConvertTo-SBRepositoryIdentity "https://user:private${at}github.com/OWNER/REPO.git") -eq 'github.com/owner/repo') 'identity normalized without credentials'
    Assert-Quick ((ConvertTo-SBRepositoryIdentity "git${at}ssh.dev.azure.com:v3/org/project/repo") -eq 'dev.azure.com/org/project/_git/repo') 'alias SSH Azure DevOps'
    Assert-Quick ($null -eq (ConvertTo-SBRepositoryIdentity 'file:///not-a-remote')) 'file remote not promoted to a global identity'
    Assert-Quick (Test-SBRepositoryIdentity ('local:'+('a'*32))) 'identita locale persistente'
    # Deterministic JSON.
    Assert-Quick ((ConvertTo-SBJson @{b=2;a=@{z=3;y=@()}}) -ceq (ConvertTo-SBJson @{a=@{y=@();z=3};b=2})) 'JSON deterministico'
    # Product releases and approved directive revisions have independent versions.
    $productVersion=(Read-SBText (Join-Path $productRoot 'VERSION')).Trim()
    $revisionLine=[regex]::Match((Read-SBText (Join-Path $productRoot 'directives/AGENTS.global_ide.md')),'(?m)^Revisi(?:on|one) (\d+\.\d+) ').Groups[1].Value
    Assert-Quick ($productVersion -match '^\d+\.\d+\.\d+$') 'VERSION uses major.minor.patch'
    Assert-Quick ($revisionLine -match '^\d+\.\d+$') 'directive revision uses major.minor independently of VERSION'
    function Test-ReadmeBadge([string]$Text,[string]$Version){$Text.Contains('https://img.shields.io/badge/version-'+$Version+'-blue') -and $Text.Contains('![Version '+$Version+']')}
    Assert-Quick (Test-ReadmeBadge (Read-SBText (Join-Path $productRoot 'README.md')) $productVersion) 'README badge matches VERSION'
    Assert-Quick (!(Test-ReadmeBadge '![Version 9.9.9](https://img.shields.io/badge/version-9.9.9-blue)' $productVersion)) 'stale README badge rejected'
    # #484 zero footprint: the user-scope text carries the loading rule and the repository files are opt-in only.
    $userScope=Get-SBPortableGlobal $productRoot
    Assert-Quick ($userScope.Contains('knowledge.ps1 -Startup') -and $userScope.Contains('get_startup_context') -and $userScope.Contains('SECONDBRAIN_HOME')) 'user-scope instructions load the context without files in the repository'
    Assert-Quick (@(ConvertTo-SBRepositoryFiles 'none').Count -eq 0 -and (@(ConvertTo-SBRepositoryFiles 'agents.md,CLAUDE.md') -join ',') -ceq 'AGENTS.md,CLAUDE.md' -and @(Get-SBBindingRepositoryFiles @{identity='x';repositoryFiles=@()}).Count -eq 0 -and @(Get-SBBindingRepositoryFiles $null).Count -eq 0) 'a binding with an empty choice, or no binding, manages no repository file'
    Assert-Quick ((@(Get-SBDefaultRepositoryFiles) -join ',') -ceq 'AGENTS.md,CLAUDE.md,GEMINI.md') 'a repository activated for the first time defaults to AGENTS.md, CLAUDE.md and GEMINI.md'
    Assert-Quick ((@(Get-SBBindingRepositoryFiles @{identity='x'}) -join ',') -ceq 'AGENTS.md,CLAUDE.md,GEMINI.md') 'un binding precedente a repositoryFiles continua a gestire AGENTS.md, CLAUDE.md e GEMINI.md'
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object Extension -in @('.ps1','.psm1')){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ('FAIL QUICK parser '+$file.Name+': '+($errors.Message -join '; '))}
    }
    Assert-Quick $true 'all PowerShell sources parse'
    # One definition per message key across scripts and modules (a duplicate silently overrides the other).
    $keyPlaces=@{}
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension -in @('.ps1','.psm1') -and $_.Name -notlike 'test-*'}){
        foreach($line in [IO.File]::ReadAllLines($file.FullName)){
            foreach($match in [regex]::Matches($line,"'([a-z0-9][a-z0-9.-]*\.[a-z0-9.-]+)'\s*=\s*@\{\s*(?:it|en)\s*=")){
                $key=$match.Groups[1].Value
                if(!$keyPlaces.ContainsKey($key)){$keyPlaces[$key]=[Collections.Generic.List[string]]::new()}
                $keyPlaces[$key].Add($file.Name+': '+$line.Trim())
            }
        }
    }
    $duplicateKeys=@($keyPlaces.GetEnumerator()|Where-Object {$_.Value.Count -gt 1}|ForEach-Object {$_.Key})
    Assert-Quick ($duplicateKeys.Count -eq 0) ('message keys defined once ('+($duplicateKeys -join ', ')+')')
    foreach($name in @('shared.json','tracker.schema.json','prompt-catalog.schema.json','prompt-catalog.schema2.json')){
        Assert-Quick (Test-Json -Json (Read-SBText (Join-Path $productRoot ('config/'+$name)))) ('valid JSON: '+$name)
    }
    $validTracker=@{schemaVersion=1;repository='github.com/test/quick';updatedAt='2026-11-04T00:00:00Z';tasks=@();history=@();extensions=@{}}
    $schema=Join-Path $productRoot 'config/tracker.schema.json'
    Assert-Quick (Test-Json -Json (ConvertTo-SBJson $validTracker) -SchemaFile $schema) 'tracker schema accepts minimal valid document'
    $validTracker.schemaVersion=99
    Assert-Quick (!(Test-Json -Json (ConvertTo-SBJson $validTracker) -SchemaFile $schema -ErrorAction SilentlyContinue)) 'tracker schema rejects unsupported version'
    # Actual prompt catalog.
    Assert-Quick (@(Get-SBWorkflowDrift $productRoot).Count -eq 0) 'catalogo reale allineato'
    # Message catalog: English only, stable keys.
    Assert-Quick ((Get-SBMessage 'core.block.duplicate' @('x')) -ceq 'Duplicate block: x') 'message text is English'
    $brainRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Assert-Quick (!(Get-Command Set-SBUiLanguage,Get-SBUiLanguage -ErrorAction SilentlyContinue) -and !(Select-String -Path (Join-Path $PSScriptRoot '*.ps1'),(Join-Path $PSScriptRoot '*.psm1') -Pattern 'SECONDBRAIN_LANG' -SimpleMatch | Where-Object { $_.Filename -notlike 'test-*' })) 'language selection (SECONDBRAIN_LANG, -Language, Set-SBUiLanguage) is removed'
    Assert-Quick ((Get-SBMessage 'chiave.inesistente') -ceq 'chiave.inesistente') 'an unknown key returns the key'
    $messageGaps=@()
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'SecondBrain.*.psm1'|Where-Object Name -ne 'SecondBrain.Messages.psm1'){Import-Module $file.FullName -Force}
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'SecondBrain.*.psm1'){
        foreach($m in [regex]::Matches((Read-SBText $file.FullName),"New-SBError '([a-z0-9._-]+)'|Get-SBMessage '([a-z0-9._-]+)'")){
            $key=if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value}
            if((Get-SBMessage $key) -ceq $key){$messageGaps+=$key}
        }
    }
    Assert-Quick (!$messageGaps.Count) ('every key used has en text'+$(if($messageGaps.Count){': '+(($messageGaps|Select-Object -Unique) -join ', ')}))
    $catalog = & (Get-Module SecondBrain.Messages) { $script:SBMessages }
    $incompleteKeys = @($catalog.Keys | Where-Object { !$catalog[$_].ContainsKey('en') -or !$catalog[$_].en -or $catalog[$_].ContainsKey('it') })
    Assert-Quick (!$incompleteKeys.Count) 'all registered message keys, including dynamic diagnostics, have en text only'
    $snapshot=Read-SBJson (Join-Path $brainRoot 'config/message-keys.caf7037.json') $null
    # Keys are registered by modules and by entry scripts, so read every Add-SBMessages table statically.
    $registered=[Collections.Generic.HashSet[string]]::new()
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Include '*.ps1','*.psm1' -File -Recurse){
        $tree=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
        foreach($call in $tree.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-SBMessages'},$true)){
            foreach($table in @($call.CommandElements|Where-Object {$_ -is [Management.Automation.Language.HashtableAst]})){foreach($pair in $table.KeyValuePairs){[void]$registered.Add([string]$pair.Item1.Value)}}
        }
    }
    $lostKeys=@($snapshot.keys|Where-Object {$_ -notin @($snapshot.removedKeys) -and !$registered.Contains($_)})
    Assert-Quick (!$lostKeys.Count) ('message key set keeps every key of caf7037'+$(if($lostKeys.Count){': '+(($lostKeys|Select-Object -First 5) -join ', ')}))
    $literalThrows=@();$scriptGaps=@()
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Include '*.ps1','*.psm1' -File|Where-Object {$_.Name -notlike 'test-*' -and $_.Name -ne 'check-distribution.ps1'}){
        $source=Read-SBText $file.FullName
        foreach($m in [regex]::Matches($source,"throw\s+(?:\(\s*)?['""]([^'""]*)['""]")){
            $literalThrows+=($file.Name+': '+$m.Groups[1].Value)
        }
        if($file.Extension -eq '.ps1'){
            foreach($m in [regex]::Matches($source,"New-SBError '([a-z0-9._-]+)'")){
                $escaped=[regex]::Escape($m.Groups[1].Value)
                $inModules=(Get-SBMessage $m.Groups[1].Value) -cne $m.Groups[1].Value
                if(!$inModules -and $source -notmatch ("'"+$escaped+"'\s*=\s*@\{\s*en\s*=")){$scriptGaps+=($file.Name+': '+$m.Groups[1].Value)}
            }
        }
    }
    # Check direct and parenthesized strings, including templates in the generated installer.
    $literalOutputs=@()
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Include '*.ps1','*.psm1' -File|Where-Object {$_.Name -notlike 'test-*' -and $_.Name -ne 'check-distribution.ps1'}){
        foreach($m in [regex]::Matches((Read-SBText $file.FullName),"Write-(?:Host|Warning|Error)\s+(?:\(\s*)?(['""])([^\r\n]*)")){
            $text=$m.Groups[2].Value
            if($text -match '^(  • \$f|`n\[\$\(\$item\.Target\.ToUpper\(\)\)\] )'){continue}
            # Formatting-only prefixes and the technical acronym IDE carry no message.
            $closingQuote=$text.IndexOf($m.Groups[1].Value)
            $literal=if($closingQuote -ge 0){$text.Substring(0,$closingQuote)}else{$text}
            if($literal -in @('`n','  {0}) {1}  [{2}]  {3}','  {0}) {1}  [{2}]','  IDE ','  ')){continue}
            $literalOutputs+=($file.Name+': '+$text.Substring(0,[Math]::Min(50,$text.Length)))
        }
    }
    Assert-Quick (!$literalOutputs.Count) ('no Write-Host/Warning/Error with literal text'+$(if($literalOutputs.Count){': '+(($literalOutputs|Select-Object -First 5) -join '; ')}))
    Assert-Quick (!$literalThrows.Count) ('no throw with literal text in modules and scripts'+$(if($literalThrows.Count){': '+(($literalThrows|Select-Object -First 5) -join '; ')}))
    Assert-Quick (!$scriptGaps.Count) ('every key used by the scripts has en text in the script'+$(if($scriptGaps.Count){': '+(($scriptGaps|Select-Object -Unique -First 5) -join '; ')}))
    Assert-Quick ((Get-SBMessage 'para.status.invalid') -ceq 'Invalid PARA status') 'catalogo messaggi: Para in en'
    # Facts quoted in the public documents derive from the code (tool count, prompt count, anchors, versions).
    $toolCount=@(& (Get-Module SecondBrain.Mcp) { Get-SBMcpToolDefinitions }).Count
    $promptCount=@((ConvertFrom-Json (Read-SBText (Join-Path $productRoot 'directives/prompts/catalog.json'))).prompts).Count
    $numberWords=@{one=1;two=2;three=3;four=4;five=5;six=6;seven=7;eight=8;nine=9;ten=10;eleven=11;twelve=12;thirteen=13;uno=1;due=2;tre=3;quattro=4;cinque=5;sei=6;sette=7;otto=8;nove=9;dieci=10;undici=11;dodici=12;tredici=13}
    $docFiles=@(Get-Item -LiteralPath (Join-Path $productRoot 'README.md'))+@(Get-ChildItem -LiteralPath (Join-Path $productRoot 'docs') -Filter '*.md' -Recurse -File)
    $staleFacts=@();$brokenAnchors=@();$versionedHeadings=@()
    function Get-QuickSlugs([string]$Text){
        $slugs=[Collections.Generic.HashSet[string]]::new();$fence=$false
        foreach($line in $Text -split "`r?`n"){
            if($line -match '^\s*(```|~~~)'){$fence=!$fence;continue}
            if(!$fence -and $line -match '^#{1,6}\s+(.+?)\s*#*\s*$'){
                $slug=([regex]::Replace($Matches[1].Trim().ToLowerInvariant(),'[^\p{L}\p{N} _-]','')) -replace ' ','-'
                [void]$slugs.Add($slug)
            }
        }
        ,$slugs
    }
    $slugCache=@{}
    foreach($doc in $docFiles){
        $text=Read-SBText $doc.FullName;$rel=$doc.FullName.Substring($productRoot.Length+1)
        foreach($line in $text -split "`r?`n"){
            # Counts of tools and prompts; lines about measured history, existing subsets or pre-authorizations are exempt.
            if($line -match '(?i)existing|esistenti|preautorizza|preauthoriz|measure|misurazion|erano|were '){continue}
            foreach($m in [regex]::Matches($line,'(?i)\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|uno|due|tre|quattro|cinque|sei|sette|otto|nove|dieci|undici|dodici|tredici)(?:\s+(?:MCP|prompt))?\s+(tools?|strumenti|prompt|prompts|schede|cards)\b')){
                $n=if($m.Groups[1].Value -match '^\d+$'){[int]$m.Groups[1].Value}else{$numberWords[$m.Groups[1].Value.ToLowerInvariant()]}
                $kind=$m.Groups[2].Value.ToLowerInvariant()
                if($kind -notin @('tool','tools','strumenti') -and $m.Groups[1].Value -notmatch '^\d+$'){continue}
                $expected=if($kind -in @('tool','tools','strumenti') -and $m.Value -notmatch '(?i)prompt'){$toolCount}else{$promptCount}
                # Tool counts below 8 describe subsets (knowledge tools, the two write tools); the full set is 8 or more.
                if($expected -eq $toolCount -and $n -lt 8){continue}
                if($n -ne $expected){$staleFacts+=($rel+': '+$m.Value+' (atteso '+$expected+')')}
            }
        }
        foreach($m in [regex]::Matches($text,'\]\(([^)#\s]*)#([^)\s]+)\)')){
            $target=if($m.Groups[1].Value){Join-Path $doc.DirectoryName $m.Groups[1].Value}else{$doc.FullName}
            if($target -notmatch '\.md$'){continue}
            if(!(Test-Path -LiteralPath $target -PathType Leaf)){$brokenAnchors+=($rel+': file '+$m.Groups[1].Value);continue}
            $full=[IO.Path]::GetFullPath($target)
            if(!$slugCache.ContainsKey($full)){$slugCache[$full]=Get-QuickSlugs (Read-SBText $full)}
            if(!$slugCache[$full].Contains($m.Groups[2].Value.ToLowerInvariant())){$brokenAnchors+=($rel+': #'+$m.Groups[2].Value)}
        }
        foreach($m in [regex]::Matches($text,'(?m)^#{1,6}\s+.*\(\d+\.\d+\.\d+\)\s*$')){$versionedHeadings+=($rel+': '+$m.Value.Trim())}
    }
    Assert-Quick ($toolCount -ge 1 -and $promptCount -ge 1) ('sources of the facts:'+$toolCount+' strumenti MCP, '+$promptCount+' prompt')
    Assert-Quick (!$staleFacts.Count) ('tool and prompt numbers in the documents consistent with the code'+$(if($staleFacts.Count){': '+(($staleFacts|Select-Object -First 5) -join '; ')}))
    Assert-Quick (!$brokenAnchors.Count) ('anchors and files of the internal document links exist'+$(if($brokenAnchors.Count){': '+(($brokenAnchors|Select-Object -Unique -First 40) -join '; ')}))
    Assert-Quick (!$versionedHeadings.Count) ('no document title tied to a version'+$(if($versionedHeadings.Count){': '+(($versionedHeadings|Select-Object -First 5) -join '; ')}))
    # Exit-code contract: every literal exit code of an entry script is a documented code (0-5) in both operations guides.
    $documentedCodes=@(0..5)
    $undocumentedExits=@()
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File|Where-Object {$_.Name -notlike 'test-*'}){
        foreach($m in [regex]::Matches((Read-SBText $file.FullName),'exit\s+(\d+)')){if([int]$m.Groups[1].Value -notin $documentedCodes){$undocumentedExits+=($file.Name+': exit '+$m.Groups[1].Value)}}
    }
    Assert-Quick (!$undocumentedExits.Count) ('script exit codes among the documented ones'+$(if($undocumentedExits.Count){': '+(($undocumentedExits|Select-Object -First 5) -join '; ')}))
    foreach($guide in @('operations.md')){
        $guideText=Read-SBText (Join-Path $productRoot ('docs/reference/'+$guide))
        $missingRows=@($documentedCodes|Where-Object {$guideText -notmatch ('(?m)^\|\s*'+$_+'\s*\|')})
        Assert-Quick (!$missingRows.Count) ('tabella dei codici di uscita completa in '+$guide)
    }
    # Module graph: no import cycle (late Import-Module calls inside functions count too).
    function Find-QuickModuleCycle([hashtable]$Graph){
        $state=@{};$stack=[Collections.Generic.List[string]]::new();$found=$null
        function Visit([string]$Node){
            if($script:found){return}
            $state[$Node]=1;$stack.Add($Node)
            foreach($next in @($Graph[$Node])){
                if(!$Graph.ContainsKey($next)){continue}
                if($state[$next] -eq 1){$script:found=(@($stack[$stack.IndexOf($next)..($stack.Count-1)])+$next) -join ' -> ';return}
                if(!$state.ContainsKey($next)){Visit $next}
                if($script:found){return}
            }
            $stack.RemoveAt($stack.Count-1);$state[$Node]=2
        }
        $script:found=$null
        foreach($node in @($Graph.Keys|Sort-Object)){if(!$state.ContainsKey($node)){Visit $node}}
        $script:found
    }
    $moduleGraph=@{}
    foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'SecondBrain.*.psm1' -File){
        $moduleGraph[$file.BaseName]=@([regex]::Matches((Read-SBText $file.FullName),"Import-Module \(Join-Path \$PSScriptRoot '(SecondBrain\.[A-Za-z]+)\.psm1'\)")|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
    }
    $cycle=Find-QuickModuleCycle $moduleGraph
    Assert-Quick (!$cycle) ('no cycle between the modules'+$(if($cycle){': '+$cycle}))
    Assert-Quick ((Find-QuickModuleCycle @{A=@('B');B=@('C');C=@('A')}) -eq 'A -> B -> C -> A') 'the anti-cycle check fails on a test cycle'
    Assert-Quick (!(Find-QuickModuleCycle @{A=@('B','C');B=@('C');C=@()})) 'the anti-cycle check accepts an acyclic graph'
    $readmeText=Read-SBText (Join-Path $productRoot 'README.md')
    Assert-Quick (!([regex]::IsMatch($readmeText,'(?i)\b(Version|versione|in) (\d+\.\d+\.\d+)\b') -and ([regex]::Matches($readmeText,'(?i)\b(Version|versione|in) (\d+\.\d+\.\d+)\b')|Where-Object {$_.Groups[2].Value -ne $productVersion}).Count)) 'il README non cita versioni diverse da VERSION'
    # Task runner selection on synthetic tasks.
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TaskRunner.psm1') -Force
    # Project isolation has no switch (#475).
    $noBrain=Join-Path ([IO.Path]::GetTempPath()) ('sb-absent-'+[guid]::NewGuid().ToString('N'))
    Assert-Quick (Test-SBProjectIsolation $noBrain) 'isolation per active project by default'
    $rootsError=try{Invoke-SBHostDiscovery -BrainRoot $noBrain -Roots @();''}catch{$_.Exception.Message}
    Assert-Quick ($rootsError -match 'Radici obbligatorie|Roots required') 'discovery without explicit roots rejected'
    # Repository dossier as a project in repos (strict per-repository perimeter).
    $paraBrain=Join-Path ([IO.Path]::GetTempPath()) ('sb-para-'+[guid]::NewGuid().ToString('N'))
    try{
        $dossier=Join-Path $paraBrain 'repos/demo--aaaaaaaa';[void](New-Item -ItemType Directory -Force $dossier)
        [IO.File]::WriteAllText((Join-Path $dossier 'entity.json'),'{"schemaVersion":1,"id":"project-demo","kind":"project","title":"demo","status":"active"}')
        [IO.File]::WriteAllText((Join-Path $dossier 'repository.json'),'{"schemaVersion":1,"identity":"github.com/acme/demo"}')
        foreach($name in @('brief.md','context.md','memory.md')){[IO.File]::WriteAllText((Join-Path $dossier $name),"# $name`n")}
        $entities=@(Get-SBParaEntities $paraBrain @())
        Assert-Quick ($entities.Count -eq 1 -and $entities[0].kind -eq 'project' -and $entities[0].repository -eq 'github.com/acme/demo') 'dossier repository come progetto in repos'
        Assert-Quick (Test-SBRepoDossier $entities[0]) 'repository dossier predicate for kind=project with a repository'
        Assert-Quick (!(Test-SBRepoDossier @{kind='project';repository=''}) -and (Test-SBRepoDossier @{kind='area'})) 'progetto a tempo non e dossier repository, area legacy si'
    }finally{if(Test-Path -LiteralPath $paraBrain){Remove-Item -LiteralPath $paraBrain -Recurse -Force}}
    $synth=@(
        [pscustomobject]@{id='A';seq=2;status='todo';priority='P2';execution='autonomous';extensions=[pscustomobject]@{stream='manutenzione-dossier'}},
        [pscustomobject]@{id='B';seq=1;status='todo';priority='P3';execution='autonomous';extensions=[pscustomobject]@{stream='evoluzione-team'}},
        [pscustomobject]@{id='C';seq=3;status='todo';priority='P1';execution='autonomous';extensions=[pscustomobject]@{stream='qualifica-finale'}},
        [pscustomobject]@{id='D';seq=4;status='blocked';priority='P1';execution='autonomous';extensions=[pscustomobject]@{stream='x'}},
        [pscustomobject]@{id='E';seq=5;status='todo';priority='P1';execution='manual';extensions=[pscustomobject]@{stream='x'}},
        [pscustomobject]@{id='F';seq=6;status='todo';priority='P1';execution='autonomous';extensions=[pscustomobject]@{stream='x';awaiting='user'}},
        [pscustomobject]@{id='G';seq=7;status='todo';priority='P0';execution='autonomous'}
    )
    $picked=@(Select-SBRunnableTasks $synth 10)
    Assert-Quick (($picked.id -join ',') -ceq 'G,A,B') 'runner: only autonomous todo, outside qualifications and human waits, by priority and seq'
    Assert-Quick (@(Select-SBRunnableTasks $synth 1).Count -eq 1) 'runner: MaxTasks limita la selezione'
    Assert-Quick ((New-SBTaskRunPrompt $picked[0]).Contains('nessun commit')-or(New-SBTaskRunPrompt $picked[0]).Contains('Nessun commit')-or(New-SBTaskRunPrompt $picked[0]).Contains('commit, push')) 'runner: il prompt vieta commit e push'
    Assert-Quick ((New-SBTaskRunPrompt $picked[0]).Contains('Scope: work only on the repository of this checkout')) 'runner: the prompt limits the work to the checkout repository'
    Assert-Quick (!(New-SBTaskRunPrompt $picked[0]).Contains('Letture consentite')) 'runner: the prompt does not cite a read allowlist (#475)'
    $decidedTask=[pscustomobject]@{id='D-1';seq=9;extensions=[pscustomobject]@{decisions=@([pscustomobject]@{questionId='q1';question='Quale sezione?';answer='Installazione'},@{questionId='q2';question='Senza risposta'})}}
    $decidedPrompt=New-SBTaskRunPrompt $decidedTask
    Assert-Quick ($decidedPrompt.Contains('Decisions already taken by the owner') -and $decidedPrompt.Contains('- Quale sezione? -> Installazione') -and !$decidedPrompt.Contains('Senza risposta') -and !(New-SBTaskRunPrompt $picked[0]).Contains('Decisions already taken by the owner')) 'runner: the prompt carries the owner decisions with an answer, only when present'
    # Read-scope guard (#382, #475): inactive without the runner variable; in a runner session global and foreign reads and writes are refused.
    $scopeNames=Get-SBRunnerScopeVariables;$savedScope=@{};foreach($n in $scopeNames.Values){$savedScope[$n]=[Environment]::GetEnvironmentVariable($n)}
    function Test-QuickScope([scriptblock]$Call){try{& $Call;$true}catch{$false}}
    try{
        foreach($n in $scopeNames.Values){[Environment]::SetEnvironmentVariable($n,$null)}
        Assert-Quick ($null -eq (Get-SBRunnerReadScope) -and (Test-QuickScope {Assert-SBRunnerReadScope -Global}) -and (Test-QuickScope {Assert-SBRunnerReadScope -Repository 'github.com/x/other' -Write})) 'runner: outside the runner the guard does not limit global reads'
        [Environment]::SetEnvironmentVariable($scopeNames.repository,'github.com/x/self')
        Assert-Quick ((Get-SBRunnerReadScope).repository -ceq 'github.com/x/self' -and $scopeNames.Count -eq 1) 'runner: perimetro dalla sola variabile del repository'
        Assert-Quick (!(Test-QuickScope {Assert-SBRunnerReadScope -Global})) 'runner: -All, -AllDossiers e all=true rifiutati nella sessione del runner'
        Assert-Quick (!(Test-QuickScope {Assert-SBRunnerReadScope -Repository 'github.com/x/other'})) 'runner: reading another repository rejected'
        Assert-Quick (Test-QuickScope {Assert-SBRunnerReadScope -Repository 'github.com/x/self'}) 'runner: lettura del repository del task consentita'
        Assert-Quick (!(Test-QuickScope {Assert-SBRunnerReadScope -Repository 'github.com/x/other' -Write}) -and (Test-QuickScope {Assert-SBRunnerReadScope -Repository 'github.com/x/self' -Write})) 'runner: writes only in the task repository'
    }finally{foreach($n in $scopeNames.Values){[Environment]::SetEnvironmentVariable($n,$savedScope[$n])}}
    # Injectable clock and identifiers (#498): fixed values, then a stepping source, then the system sources again.
    $fixedNow=[DateTimeOffset]::new(2026,11,13,10,30,0,[TimeSpan]::Zero)
    try{
        Set-SBClockSource {[DateTimeOffset]::new(2026,11,13,10,30,0,[TimeSpan]::Zero)}
        Assert-Quick ((Get-SBNow).ToString('o') -ceq '2026-11-13T10:30:00.0000000+00:00' -and (Get-SBNow).Offset -eq [TimeSpan]::Zero) 'orologio fisso: Get-SBNow restituisce il valore iniettato in UTC'
        Assert-Quick ((Get-SBNow).AddDays(-14).ToString('yyyyMMdd') -ceq '20261030' -and (Get-SBNow -Local).UtcDateTime -eq $fixedNow.UtcDateTime) 'orologio fisso: aritmetica e variante locale coerenti'
        $script:tick=0;Set-SBClockSource {$script:tick++;[DateTimeOffset]::new(2026,11,13,10,30,0,[TimeSpan]::Zero).AddSeconds($script:tick)}
        Assert-Quick (((Get-SBNow)-(Get-SBNow)).TotalSeconds -eq -1) 'stepped clock: each read advances by one second'
        $script:seq=0;Set-SBIdSource {$script:seq++;('{0:x32}' -f $script:seq)}
        Assert-Quick ((New-SBId) -ceq ('0'*31+'1') -and (New-SBId) -ceq ('0'*31+'2')) 'ID iniettati: sequenza deterministica'
        Set-SBClockSource $null;Set-SBIdSource $null
        $real=New-SBId
        Assert-Quick ($real -match '^[0-9a-f]{32}$' -and $real -cne (New-SBId) -and [Math]::Abs(((Get-SBNow)-[DateTimeOffset]::UtcNow).TotalMinutes) -lt 1) 'senza iniezione: GUID e orologio di sistema'
    }finally{Set-SBClockSource $null;Set-SBIdSource $null}
    # Only Core reads the system clock or creates GUIDs outside the tests.
    $direct=@(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension -in '.ps1','.psm1' -and $_.Name -notlike 'test-*' -and $_.Name -ne 'SecondBrain.Core.psm1'}|Select-String -Pattern 'Get-Date|\[Date[Tt]ime(Offset)?\]::(Now|UtcNow)|NewGuid|Get-Random')
    Assert-Quick ($direct.Count -eq 0) ('no direct clock or GUID outside Core and the tests'+$(if($direct.Count){': '+$direct[0].Filename+':'+$direct[0].LineNumber}))
    # Tracker merge: messages keyed, source detection moved with the merge module, no Git needed for detection.
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TrackerMerge.psm1') -Force
    Assert-Quick ((Get-SBMessage 'trackermerge.conflict.seq' @(3,'ONB-3')) -match 'Sequence number 3 already belongs to task ONB-3') 'tracker merge: conflict messages come from Add-SBMessages keys'
    $mergeProbe=Join-Path ([IO.Path]::GetTempPath()) ('sb-merge-probe-'+[guid]::NewGuid().ToString('N'))
    try{
        [void][IO.Directory]::CreateDirectory($mergeProbe)
        [IO.File]::WriteAllText((Join-Path $mergeProbe 'tasks.json'),'{"tasks":[]}')
        $probe=Get-SBCheckoutTrackerSource $mergeProbe 'github.com/test/probe'
        Assert-Quick ($probe.path -ceq 'tasks.json' -and !$probe.compatible -and $null -eq (Get-SBCheckoutTrackerSource (Join-Path $mergeProbe 'absent') 'github.com/test/probe')) 'tracker merge: checkout tracker source detection'
    }finally{if(Test-Path -LiteralPath $mergeProbe){Remove-Item -LiteralPath $mergeProbe -Recurse -Force}}
    'SUCCESS QUICK: '+$script:quickChecks+' pure checks (no Git, no child process).'
} finally { }
