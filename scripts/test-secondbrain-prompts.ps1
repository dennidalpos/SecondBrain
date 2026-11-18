#requires -Version 7.5
# Prompt library: single catalog, card format, composition, listing, drift. Read-only on the real catalog.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$brain=Split-Path $PSScriptRoot -Parent
$script:promptChecks=0
function Assert-Prompts($Condition,[string]$Message){if(!$Condition){throw 'FAIL PROMPTS: '+$Message};$script:promptChecks++;'PASS PROMPTS: '+$Message}
$catalog=Read-SBWorkflowCatalog $brain -ValidateBodies -ValidateReferences
$prompts=@($catalog.prompts)
# #617: the question rule in generated prompts covers the missing-tool fallback and subagents.
$ruleSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Raw
Assert-Prompts ($ruleSource -match "rule='[^']*structured question tool[^']*capability is missing[^']*numbered options[^']*pause the dependent work") '#617: without a question tool the capability is reported, the fallback is text and dependent work pauses'
Assert-Prompts ($ruleSource -match "rule='[^']*subagent returns its question to the parent and never answers it") '#617: subagent questions go to the parent, never answered by the subagent'
Assert-Prompts ($prompts.Count -ge 80) ('catalogo unico con '+$prompts.Count+' prompt')
Assert-Prompts (@($prompts.code|Select-Object -Unique).Count -eq $prompts.Count) 'codici univoci'
Assert-Prompts (@($prompts.id|Select-Object -Unique).Count -eq $prompts.Count) 'ID univoci'
Assert-Prompts (!(@($prompts|Where-Object {$_.id -notmatch '^pmt-[0-9a-f]{8}$'}).Count)) 'ID nel formato pmt-xxxxxxxx'
$raw=Get-Content -Raw -LiteralPath (Join-Path $brain 'direttive/prompts/catalog.json')
foreach($legacy in 'pack','deprecations','aliases','supersededBy','next','references','status'){Assert-Prompts ($raw -notmatch ('"'+$legacy+'"\s*:')) "il catalogo non contiene la chiave $legacy"}
Assert-Prompts (!(Test-Path -LiteralPath (Join-Path $brain 'direttive/prompts/en'))) 'nessuna cartella en/ legacy'
Assert-Prompts (!(Get-ChildItem -LiteralPath (Join-Path $brain 'direttive/prompts') -Filter 'README.maintenance*')) 'nessun README.maintenance legacy'
foreach($p in $prompts){
    $en=Join-Path $brain ('direttive/prompts/'+$p.code+'.md')
    if(!(Test-Path -LiteralPath $en)){Assert-Prompts $false ($p.code+': scheda presente')}
    $enText=Get-Content -Raw -LiteralPath $en
    foreach($tag in 'role','context','inputs','procedure','constraints','exit_criteria','output_format'){
        if($enText -notmatch "(?m)^<$tag>\s*$"){Assert-Prompts $false ($p.code+': tag '+$tag)}
    }
    if($enText.Length -gt 6500){Assert-Prompts $false ($p.code+': scheda oltre 6.500 caratteri ('+$enText.Length+')')}
    if($enText -match '\bask_question\b'){Assert-Prompts $false ($p.code+': nome di tool non standard')}
}
Assert-Prompts $true 'ogni scheda ha i tag obbligatori, dimensione contenuta e nessun nome di tool non standard'
# Every related code exists; every category is used.
$ids=@($prompts.id)
Assert-Prompts (!(@($prompts|ForEach-Object {$_.related}|Where-Object {$_ -notin $ids}).Count)) 'related punta a ID esistenti'
Assert-Prompts (!(@($prompts|Where-Object {$_.id -in $_.related}).Count)) 'nessun prompt correlato a sé stesso'
# Groups: central categories hold only central prompts and repository categories none; every category has a group.
foreach($category in $catalog.categories){
    $members=@($prompts|Where-Object category -eq $category.id)
    $expectedTarget=if($category.group -eq 'central'){'central'}else{'repository'}
    Assert-Prompts (@($members|Where-Object target -ne $expectedTarget).Count -eq 0) ('categoria '+$category.id+': gruppo '+$category.group+' coerente con la destinazione dei prompt')
}
# Perimeter: a repository prompt works on the repository it runs from; the only cross-repository reads are declared allowlists (REP16).
foreach($p in @($prompts|Where-Object {$_.target -eq 'repository' -and $_.code -ne 'REP16'})){
    foreach($relative in @($p.file)){
        $body=Get-Content -Raw -LiteralPath (Join-Path $brain ('direttive/prompts/'+$relative))
        Assert-Prompts ($body -notmatch '(?i)para-index|para\.ps1|-AllDossiers|\.runtime|central maintenance|manutenzione centrale') ($p.code+' ('+$relative+'): nessun riferimento oltre il repository corrente')
    }
}
# Related: a code cited in a card must be listed among its related prompts, and cited codes must exist.
$relatedRoot=Join-Path (Get-SBTestRoot) ('fixture-'+(Get-Date -Format 'yyyyMMdd')+'-related-'+[guid]::NewGuid().ToString('N').Substring(0,8))
foreach($folder in 'direttive/prompts','config'){[void][IO.Directory]::CreateDirectory((Join-Path $relatedRoot $folder))}
Copy-Item -LiteralPath (Join-Path $brain 'direttive/prompts') -Destination (Join-Path $relatedRoot 'direttive') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $brain 'config/prompt-catalog.schema.json') -Destination (Join-Path $relatedRoot 'config/prompt-catalog.schema.json') -Force
Assert-Prompts ($null -ne (Read-SBWorkflowCatalog $relatedRoot -ValidateBodies -ValidateReferences)) 'related: copia di prova valida'
$relatedCatalogPath=Join-Path $relatedRoot 'direttive/prompts/catalog.json'
$relatedCatalog=Read-SBJson $relatedCatalogPath @{}
$victim=@($relatedCatalog.prompts|Where-Object {$_.code -eq 'AUD01'})[0]
$victim.related=@($victim.related|Select-Object -First 1)
[IO.File]::WriteAllText($relatedCatalogPath,(ConvertTo-SBJson $relatedCatalog),[Text.UTF8Encoding]::new($false))
$uncited=$false
try{[void](Read-SBWorkflowCatalog $relatedRoot -ValidateBodies -ValidateReferences)}catch{$uncited=Test-SBError $_ 'prompts.related.uncited'}
Assert-Prompts $uncited 'related: codice citato ma non elencato respinto'
Copy-Item -LiteralPath (Join-Path $brain 'direttive/prompts/catalog.json') -Destination $relatedCatalogPath -Force
$danglingCard=Join-Path $relatedRoot 'direttive/prompts/DEV01.md'
[IO.File]::WriteAllText($danglingCard,(([IO.File]::ReadAllText($danglingCard)).Replace("`n</context>"," See DEV99.`n</context>")),[Text.UTF8Encoding]::new($false))
$dangling=$false
try{[void](Read-SBWorkflowCatalog $relatedRoot -ValidateBodies -ValidateReferences)}catch{$dangling=Test-SBError $_ 'prompts.reference.dangling'}
Assert-Prompts $dangling 'related: codice citato inesistente respinto'
# Listing.
$list=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prompts.ps1') -List -Compact
Assert-Prompts ($LASTEXITCODE -eq 0 -and ($list -join "`n") -match 'SYS03' -and ($list -join "`n") -match 'MEM05') 'elenco compatto con prompt di sistema e memoria nella stessa lista'
$cat=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prompts.ps1') -List -Category TST
Assert-Prompts ($LASTEXITCODE -eq 0 -and ($cat -join "`n") -match 'TST04') 'elenco per categoria'
$show=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prompts.ps1') -Show -Prompt TST04
Assert-Prompts ($LASTEXITCODE -eq 0 -and ($show -join "`n") -match 'TST04') 'scheda mostrata per codice'
$byId=($prompts|Where-Object code -eq 'TST04').id
$showId=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'prompts.ps1') -Show -Prompt $byId
Assert-Prompts ($LASTEXITCODE -eq 0 -and ($showId -join "`n") -eq ($show -join "`n")) 'ID e codice risolvono la stessa scheda'
# Composition: XML structure, objective honored, closing depends on mode.
$ctx=@{repositories=@();sourceRegistry=$null;project=$null}
$readPrompt=$prompts|Where-Object {$_.mode -eq 'read'}|Select-Object -First 1
$writePrompt=$prompts|Where-Object {$_.mode -eq 'write' -and $_.code -notmatch '^(MEM|SYS)'}|Select-Object -First 1
$objective='Obiettivo di prova 4242'
$readOut=New-SBWorkflowComposition $brain $catalog $readPrompt $ctx $objective -Standalone
Assert-Prompts ($readOut -match '(?s)<prompt code="'+$readPrompt.code+'".*<task>\s*'+[regex]::Escape($objective)+'\s*</task>.*<role>.*<procedure>.*<exit_criteria>.*<output_format>.*</prompt>') 'composizione XML con obiettivo, ruolo, procedura, criteri e formato'
$writeOut=New-SBWorkflowComposition $brain $catalog $writePrompt $ctx '' -Standalone
Assert-Prompts ($writeOut -ne $readOut -and $writeOut -match '<operating_rules>') 'regole operative presenti anche in scrittura'
$closingRead=([regex]::Match($readOut,'(?s)<operating_rules>(.*?)</operating_rules>')).Groups[1].Value
$closingWrite=([regex]::Match($writeOut,'(?s)<operating_rules>(.*?)</operating_rules>')).Groups[1].Value
Assert-Prompts ($closingRead -ne $closingWrite) 'la chiusura del task dipende dalla modalità'
# Language: the composition is English only.
Assert-Prompts ($readOut -match 'language="en"') 'composition language is English'
# Pointer files for agents that do not read AGENTS.md (Claude Code, Gemini CLI): created, idempotent, preserve user text, conflict on foreign edits.
$pointerRoot=Join-Path (Get-SBTestRoot) ('fixture-'+(Get-Date -Format 'yyyyMMdd')+'-pointers-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[IO.Directory]::CreateDirectory($pointerRoot)|Out-Null
$pointerBackup=Join-Path $pointerRoot 'backups';$pointerState=@{}
[IO.File]::WriteAllText((Join-Path $pointerRoot 'CLAUDE.md'),"# Note utente`nIstruzioni personali.`n")
$preview=@(Set-SBRepositoryPointers $pointerRoot $pointerState $true $pointerBackup)
Assert-Prompts (@($preview|Where-Object result -eq 'pending').Count -eq 2 -and !(Test-Path -LiteralPath (Join-Path $pointerRoot 'GEMINI.md'))) 'anteprima dei puntatori senza scrivere'
$applied=@(Set-SBRepositoryPointers $pointerRoot $pointerState $false $pointerBackup)
$claude=Get-Content -Raw -LiteralPath (Join-Path $pointerRoot 'CLAUDE.md')
$gemini=Get-Content -Raw -LiteralPath (Join-Path $pointerRoot 'GEMINI.md')
Assert-Prompts (@($applied|Where-Object result -eq 'updated').Count -eq 2 -and $claude.Contains('@AGENTS.md') -and $claude.Contains('Istruzioni personali.') -and $gemini.Contains('@AGENTS.md')) 'puntatori creati e testo utente preservato'
Assert-Prompts (@(Set-SBRepositoryPointers $pointerRoot $pointerState $false $pointerBackup|Where-Object result -ne 'aligned').Count -eq 0) 'puntatori idempotenti'
$crlf=(Get-Content -Raw -LiteralPath (Join-Path $pointerRoot 'CLAUDE.md')) -replace "`r?`n","`r`n"
[IO.File]::WriteAllText((Join-Path $pointerRoot 'CLAUDE.md'),$crlf)
Assert-Prompts (@(Set-SBRepositoryPointers $pointerRoot $pointerState $true $pointerBackup|Where-Object {$_.file -eq 'CLAUDE.md'}).result -eq 'aligned') 'puntatore con terminatori CRLF (autocrlf) resta allineato'
[IO.File]::WriteAllText((Join-Path $pointerRoot 'GEMINI.md'),($gemini -replace '@AGENTS.md','@ALTRO.md'))
Assert-Prompts (@(Set-SBRepositoryPointers $pointerRoot $pointerState $true $pointerBackup|Where-Object {$_.file -eq 'GEMINI.md'}).result -eq 'conflict') 'modifica esterna del blocco segnalata come conflitto'
$pointerBinaryCount=@(Get-ChildItem -LiteralPath $pointerBackup -Filter '*.bin').Count
$geminiPath=Join-Path $pointerRoot 'GEMINI.md'
$pointerState[$geminiPath+'|pointer']=Get-SBTextHash ((Read-SBText $geminiPath).Trim())
$updatedPointer=@(Set-SBRepositoryPointers $pointerRoot $pointerState $false $pointerBackup|Where-Object file -eq 'GEMINI.md')
Assert-Prompts ($updatedPointer.result -eq 'updated' -and (Read-SBText $geminiPath) -ceq $gemini -and @(Get-ChildItem -LiteralPath $pointerBackup -Filter '*.bin').Count -eq $pointerBinaryCount) 'puntatore interamente generato aggiornato senza copia binaria'
$personalBackup=@(Get-ChildItem -LiteralPath $pointerBackup -Filter '*.bin'|Where-Object {(Read-SBText $_.FullName) -ceq "# Note utente`nIstruzioni personali.`n"})
Assert-Prompts ($personalBackup.Count -eq 1) 'puntatore misto mantiene una copia esatta delle istruzioni personali'
# Encoding guard: exercise both read boundaries, including corruption in a body beyond its title.
$encodingRoot=Join-Path $pointerRoot 'encoding'
$encodingCatalog=Join-Path $encodingRoot 'direttive/prompts/catalog.json'
$encodingCard=Join-Path $encodingRoot ('direttive/prompts/'+$readPrompt.file)
$encodingBackup=Join-Path $pointerRoot 'encoding-backups'
$validUnicode='Usabilità, può, receção, cessação, … — • ⚠ 🔭 ├── 中文'
& (Get-Module SecondBrain.Prompts) {param($Text) Assert-SBWorkflowEncoding $Text 'valid-unicode'} $validUnicode
Assert-Prompts $true 'codifica: accenti, portoghese, emoji, punteggiatura, cinese e alberi Unicode validi'
$badSequences=@(
    (-join ([char[]]@(0x251C,0x00E1))),
    (-join ([char[]]@(0x251C,0x2593))),
    (-join ([char[]]@(0x00E2,0x20AC,0x00A2))),
    (-join ([char[]]@(0x00E2,0x20AC,0x201D))),
    (-join ([char[]]@(0x00E2,0x20AC,0x00A6))),
    (-join ([char[]]@(0x00E2,0x0161,0x00A0))),
    ([string][char]0xFFFD)
)
foreach($bad in $badSequences){
    $badJson=ConvertTo-SBJson @{text=('Fixture '+$bad)}
    Write-SBFile $encodingCatalog ([Text.Encoding]::UTF8.GetBytes($badJson)) (Get-SBFileHash $encodingCatalog) $encodingBackup|Out-Null
    $catalogRejected=$false
    try{[void](Read-SBWorkflowCatalog $encodingRoot)}catch{$catalogRejected=Test-SBError $_ 'prompts.encoding.invalid'}
    Assert-Prompts $catalogRejected 'codifica: catalogo corrotto respinto con codice stabile'
    $badCard='# '+$readPrompt.code+' — Fixture'+[Environment]::NewLine+'<context>'+[Environment]::NewLine+$bad
    Write-SBFile $encodingCard ([Text.Encoding]::UTF8.GetBytes($badCard)) (Get-SBFileHash $encodingCard) $encodingBackup|Out-Null
    $cardRejected=$false
    try{[void](Read-SBWorkflowPrompt $encodingRoot $readPrompt $catalog)}catch{$cardRejected=Test-SBError $_ 'prompts.encoding.invalid'}
    Assert-Prompts $cardRejected 'codifica: corpo scheda corrotto respinto con codice stabile'
}
# Generated indexes are in sync.
$drift=Get-SBWorkflowDrift $brain
Assert-Prompts (!@($drift).Count) 'indici generati allineati al catalogo'
# Directives: the newest proposal (candidate or active text) respects structure, size and consistency with the prompt registry.
$proposalRoot=Join-Path $brain 'direttive/proposals'
$latest=Get-ChildItem -LiteralPath $proposalRoot -Directory|Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'AGENTS.global_ide.md')}|Sort-Object Name|Select-Object -Last 1
$global=Get-Content -Raw -Encoding utf8 (Join-Path $latest.FullName 'AGENTS.global_ide.md')
$station=Get-Content -Raw -Encoding utf8 (Join-Path $latest.FullName 'workstation.template.md')
$repoBlock=Get-Content -Raw -Encoding utf8 (Join-Path $latest.FullName 'AGENTS.repo.managed.md')
Assert-Prompts ($global.Length -le 5500) ('testo comune entro 5.500 caratteri ('+$global.Length+')')
Assert-Prompts ($station.Length -le 3200) ('testo di postazione entro 3.200 caratteri ('+$station.Length+')')
Assert-Prompts ($repoBlock.Length -le 3200) ('blocco repository entro 3.200 caratteri ('+$repoBlock.Length+')')
Assert-Prompts ($global -match '(?m)^Revisi(?:on|one) \d+\.\d+ — \d{4}-\d{2}-\d{2}\.') 'riga di revisione leggibile dal registro'
$headings=[ordered]@{
    'Principi'='Principles'
    'Sicurezza e dati'='Security and data'
    'SecondBrain'='SecondBrain'
    'Verifica'='Verification'
    'Git e pubblicazione'='Git and publication'
    'Chiusura'='Closing work'
}
foreach($heading in $headings.Keys){
    $italian=[regex]::Escape($heading)
    $english=[regex]::Escape($headings[$heading])
    Assert-Prompts ($global -match "(?m)^## (?:$italian|$english)\s*$") "sezione '$heading' nel testo comune"
}
Assert-Prompts ($global -notmatch 'ask_question|Function Calling') 'nessun nome di strumento non standard nel testo comune'
foreach($text in $global,$station,$repoBlock){Assert-Prompts ($text -notmatch '(?<![A-Za-z0-9+.-])[A-Z]:[\/]|(?<![\w/])/(?:Users|home)/|\{\{') 'nessun percorso assoluto o segnaposto'}
Assert-Prompts ($station.Contains('<!-- secondbrain:tracker-contract:1 -->')) 'contratto tracker presente nel testo di postazione'
$registry=@(Get-SBWorkflowCommands|ForEach-Object {$_.command})
$english='sb activate','sb check','sb sync','sb compact','sb stop','sb prompt list','sb prompt area AREA','sb prompt show KEY'
foreach($command in $english){Assert-Prompts ($command -in $registry) "command '$command' in the registry"}
# English-only (3.0): the Italian verbs of revisions up to 1.2 are no longer aliases.
$aliases=@(Get-SBWorkflowCommands|ForEach-Object {@($_.aliases)})
Assert-Prompts ($aliases.Count -eq 0) 'the verb registry has no aliases (Italian sb verbs removed)'
Assert-Prompts ((@(Get-SBWorkflowCommands|Where-Object command -eq 'sb stop')[0].script) -match '-Prompt session.stop$') 'sb stop compone il ruolo session.stop'
$extended='sb tasks','sb next','sb pending','sb pending flush','sb runner status','sb publish check','sb grants','sb projects','sb status','sb ides','sb backup','sb backup verify','sb sources','sb cleanup','sb bindings','sb recover','sb directives check','sb directives propose','sb prompts check'
foreach($command in $extended){Assert-Prompts ($command -in $registry) "command '$command' in the registry"}
Assert-Prompts (@($registry|Group-Object|Where-Object Count -gt 1).Count -eq 0) 'the command registry has no duplicates'
foreach($entry in @(Get-SBWorkflowCommands)){
    Assert-Prompts ($entry.scope -in @('repository','secondbrain') -and $entry.does -and $entry.mode) "command '$($entry.command)' has scope, description and mode"
    $scriptName=[regex]::Match($entry.script,'^scripts/([A-Za-z0-9.-]+\.ps1)').Groups[1].Value
    Assert-Prompts ($scriptName -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot $scriptName))) "command '$($entry.command)' points to an existing script"
}
# #724: every registry command resolves through the sb dispatcher to an existing script; help lists them all.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Dispatch.psm1') -Force
foreach($entry in @(Get-SBWorkflowCommands)){
    $words=@(($entry.command -replace '^sb ','' -replace ':','') -split ' '|ForEach-Object {$_ -creplace '^(KEY|AREA|TEXT)$','x'})
    $plan=Resolve-SBDispatch $words
    Assert-Prompts ($plan.script -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot $plan.script))) "sb dispatcher resolves '$($entry.command)' to an existing script"
}
Assert-Prompts ((Resolve-SBDispatch @()).help -and (Resolve-SBDispatch @('help')).help) 'sb help and bare sb show the command list'
Assert-Prompts (((Resolve-SBDispatch @('prompt','show','x')).arguments -join ' ') -ceq '-Show -Prompt x') 'sb prompt show KEY resolves to -Show -Prompt'
$unknownError=$null;try{Resolve-SBDispatch @('bogus')|Out-Null}catch{$unknownError=$_}
Assert-Prompts ($null -ne $unknownError) 'an unknown sb command is refused'
foreach($word in $english){Assert-Prompts ($station.Contains($word)) "command '$word' described in the workstation text"}
$referenced=@([regex]::Matches($global+$station+$repoBlock,'(?:COM|PRG|DEV|TST|SEC|AUD|INT|DAT|OPS|DOC|REP|GOV|MEM|SYS)\d{2}')|ForEach-Object {$_.Value}|Select-Object -Unique)
Assert-Prompts (!(@($referenced|Where-Object {$_ -notin @($prompts.code)}).Count)) 'ogni codice prompt citato nelle direttive esiste nel catalogo'
# #589: private repository cards and workflows in the dossier, namespaced keys, no shadowing, no public reference to them.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PrivateAssets.psm1') -Force
$privateRoot=Join-Path (Get-SBTestRoot) ('private-assets-'+[guid]::NewGuid().ToString('N').Substring(0,12))
function Write-PrivateFixture([string]$Relative,[string]$Text){$p=Join-Path $privateRoot $Relative;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$Text,[Text.UTF8Encoding]::new($false))}
function New-PrivateCardText([string]$Key,[string]$Summary){"# $Key — $($Summary.TrimEnd('.'))`n<role>`nRelease operator.`n</role>`n<context>`nSigning of this repository.`n</context>`n<inputs>`n- the package`n</inputs>`n<procedure>`n1. Build.`n2. Sign.`n</procedure>`n<constraints>`n- No publication.`n</constraints>`n<exit_criteria>`n- Signed package.`n</exit_criteria>`n<output_format>`nReport.`n</output_format>`n"}
function New-PrivateDossier([string]$Name,[string]$Identity,$Cards,$Flows=@()){
    foreach($sub in 'prompts','workflows'){$dir=Join-Path $privateRoot "repos/$Name/$sub";if(Test-Path -LiteralPath $dir){Remove-Item -LiteralPath $dir -Recurse -Force}}
    Write-PrivateFixture "repos/$Name/repository.json" (ConvertTo-SBJson @{schemaVersion=1;identity=$Identity})
    if($null -ne $Cards){
        Write-PrivateFixture "repos/$Name/prompts/catalog.json" (ConvertTo-SBJson @{schemaVersion=1;repository=$Identity;prompts=@($Cards|ForEach-Object {$_.entry})})
        foreach($card in @($Cards)){if($card.text){Write-PrivateFixture ("repos/$Name/prompts/"+$card.entry.file) $card.text}}
    }
    foreach($flow in @($Flows)){Write-PrivateFixture ("repos/$Name/workflows/"+(($flow.key -split '/',2)[1])+'.json') (ConvertTo-SBJson $flow)}
}
function New-PrivateCard([string]$Id,[string]$Key,[string]$Mode='write',[bool]$Destructive=$false,[string]$Status='active',$Related=@()){
    $summary='Sign the release package of this repository.'
    $entry=[ordered]@{id=$Id;key=$Key;summary=$summary;mode=$Mode;destructive=$Destructive;target='repository';revision=1;status=$Status;file=(($Key -split '/',2)[1]+'.md')}
    if(@($Related).Count){$entry.related=@($Related)}
    @{entry=$entry;text=(New-PrivateCardText $Key $summary)}
}
function Assert-PrivateRefused([scriptblock]$Action,[string]$Code,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=(Test-SBError $_ $Code)};Assert-Prompts $refused $Message}
try{
    $publicId=[string]$prompts[0].id
    Write-PrivateFixture 'direttive/prompts/catalog.json' '{"schemaVersion":1}'
    $sign=New-PrivateCard 'pmt-a0000001' 'acme-app/pkg-sign' 'write' $false 'active' @($publicId)
    $draft=New-PrivateCard 'pmt-a0000002' 'acme-app/pkg-draft' 'read' $false 'draft'
    $wipe=New-PrivateCard 'pmt-a0000003' 'acme-app/pkg-wipe' 'write' $true
    $flow=[ordered]@{schemaVersion=1;id='wfl-a0000001';key='acme-app/release';title='Release';revision=1;status='active';steps=@(
        [ordered]@{step='check';ref=$publicId;kind='required';gate='auto'},
        [ordered]@{step='sign';ref='pmt-a0000001';kind='required';gate='confirm'},
        [ordered]@{step='clean';ref='pmt-a0000003';kind='optional';gate='confirm'})}
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @($sign,$draft,$wipe) @($flow)
    New-PrivateDossier 'beta' 'github.com/acme/Beta' @(New-PrivateCard 'pmt-b0000001' 'beta/notes' 'read')
    $setA=Read-SBPrivateAssets -Dossier (Join-Path $privateRoot 'repos/acme-app') -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog
    Assert-Prompts (@($setA.prompts).Count -eq 3 -and @($setA.workflows).Count -eq 1 -and $setA.slug -eq 'acme-app') '#589: private cards and workflows load from the dossier with the repository slug'
    Assert-Prompts ((Get-SBRepositorySlug 'github.com/acme/Beta') -eq 'beta') '#589: the slug is the lowercased last segment of the identity'
    $listA=Format-SBPrivatePromptList $setA
    Assert-Prompts ($listA.Contains('acme-app/pkg-sign') -and !$listA.Contains('acme-app/pkg-draft') -and !$listA.Contains('beta/notes') -and $listA.Contains('acme-app/release')) '#589: the listing shows only active private assets of its own repository'
    $composed=New-SBPrivatePromptComposition $setA (Resolve-SBPrivatePrompt $setA 'acme-app/pkg-sign') 'sign 1.2'
    Assert-Prompts ($composed.Contains('private="true"') -and $composed.Contains('Objective: sign 1.2') -and $composed.Contains('# acme-app/pkg-sign')) '#589: a private card composes by its namespaced key'
    Assert-PrivateRefused {Resolve-SBPrivatePrompt $setA 'beta/notes'} 'private.notfound' '#589: another repository private key does not resolve here'
    $summary=Test-SBPrivateAssets -BrainRoot $privateRoot -PublicCatalog $catalog
    Assert-Prompts ($summary.dossiers -eq 2 -and $summary.prompts -eq 4 -and $summary.workflows -eq 1) '#589: the workstation check validates every dossier with private assets'
    # Keys, collisions and references.
    $bad=Join-Path $privateRoot 'repos/acme-app'
    $restore={New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @($sign,$draft,$wipe) @($flow)}
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @(New-PrivateCard 'pmt-a0000001' 'pkg-sign')
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.invalid' '#589: a key without the repository namespace is refused'
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @(New-PrivateCard 'pmt-a0000001' 'beta/pkg-sign')
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.invalid' '#589: a key in another repository namespace is refused'
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @(New-PrivateCard $publicId 'acme-app/pkg-sign')
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.collision' '#589: a private card reusing a public ID is a collision'
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @(New-PrivateCard 'pmt-b0000001' 'acme-app/pkg-sign')
    Assert-PrivateRefused {Test-SBPrivateAssets -BrainRoot $privateRoot -PublicCatalog $catalog} 'private.collision' '#589: two dossiers sharing a private ID are a collision'
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @(New-PrivateCard 'pmt-a0000001' 'acme-app/pkg-sign' 'write' $false 'active' @('pmt-b0000001'))
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.reference' '#589: a private card citing another dossier private card is refused'
    & $restore
    $unsafe=[ordered]@{}+$flow;$unsafe.steps=@([ordered]@{step='clean';ref='pmt-a0000003';kind='required';gate='auto'})
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @($sign,$draft,$wipe) @($unsafe)
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.invalid' '#589: a destructive workflow step without a confirm gate is refused'
    $deep1=[ordered]@{schemaVersion=1;id='wfl-a0000002';key='acme-app/outer';title='Outer';revision=1;status='active';steps=@([ordered]@{step='inner';ref='wfl-a0000003';kind='required';gate='auto'})}
    $deep2=[ordered]@{schemaVersion=1;id='wfl-a0000003';key='acme-app/inner';title='Inner';revision=1;status='active';steps=@([ordered]@{step='deepest';ref='wfl-a0000001';kind='required';gate='auto'})}
    New-PrivateDossier 'acme-app' 'github.com/acme/acme-app' @($sign,$draft,$wipe) @($flow,$deep1,$deep2)
    Assert-PrivateRefused {Read-SBPrivateAssets -Dossier $bad -Repository 'github.com/acme/acme-app' -PublicCatalog $catalog} 'private.invalid' '#589: workflow nesting deeper than 2 is refused'
    & $restore
    # Public files never cite a private asset.
    Write-PrivateFixture 'direttive/prompts/SYS99.md' 'See acme-app/pkg-sign for the signing steps.'
    Assert-PrivateRefused {Test-SBPrivateAssets -BrainRoot $privateRoot -PublicCatalog $catalog} 'private.public.reference' '#589: a public card citing a private key is refused'
    Assert-Prompts (@(Get-SBPrivateAssetTokens $privateRoot) -contains 'acme-app/pkg-sign' -and @(Find-SBPrivateReferences $privateRoot @('acme-app/pkg-sign')).Count -eq 1) '#589: the publication scan tokens include private keys and find the public reference'
    Write-PrivateFixture 'direttive/proposals/old/proposal.md' 'Historical mention of pmt-a0000001.'
    Remove-Item -LiteralPath (Join-Path $privateRoot 'direttive/prompts/SYS99.md') -Force
    Assert-Prompts ((Test-SBPrivateAssets -BrainRoot $privateRoot -PublicCatalog $catalog).publicReferences -eq 0) '#589: historical proposals are excluded from the public reference rule'
}finally{
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $privateRoot)){Remove-Item -LiteralPath $privateRoot -Recurse -Force}
}
# #566: catalog schema 2 (pack, surface, roles, required destructive), alias table and workflow schema; the loader still reads schema 1.
$s2Root=Join-Path (Get-SBTestRoot) ('schema2-'+[guid]::NewGuid().ToString('N').Substring(0,12))
function Write-S2([string]$Relative,[string]$Text){$p=Join-Path $s2Root $Relative;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$Text,[Text.UTF8Encoding]::new($false))}
function New-S2Card([string]$Id,[string]$Code,$Extra=@{}){
    $card=[ordered]@{id=$Id;code=$Code;category='understand';summary='Summary of the card.';target='repository';mode='read';destructive=$false;surface='chat';pack='core';requires='Nothing.';example=($Code+': check');file=($Code+'.md')}
    foreach($k in $Extra.Keys){if($null -eq $Extra[$k]){$card.Remove($k)}else{$card[$k]=$Extra[$k]}}
    $card
}
function Write-S2Catalog($Cards,[int]$Version=2){
    $cat=[ordered]@{schemaVersion=$Version;catalogVersion=$Version;categories=@(@{id='understand';group='repository';title='Understanding'});prompts=@($Cards)}
    Write-S2 'direttive/prompts/catalog.json' (ConvertTo-SBJson $cat)
}
function Assert-S2Refused([scriptblock]$Action,[string]$Code,[string]$Message){$refused=$false;try{& $Action|Out-Null}catch{$refused=(Test-SBError $_ $Code)};Assert-Prompts $refused $Message}
$flowHead='{"schemaVersion":1,"id":"wfl-c0000001","key":"wf-core","title":"Core flow","revision":1,"status":"active","steps":['
try{
    foreach($f in 'prompt-catalog.schema.json','prompt-catalog.schema2.json','prompt-workflow.schema.json','prompt-aliases.schema.json'){Write-S2 ('config/'+$f) (Get-Content -Raw -LiteralPath (Join-Path $brain ('config/'+$f)))}
    $a=New-S2Card 'pmt-b0000001' 'AAA01' @{role='stop'}
    $b=New-S2Card 'pmt-b0000002' 'AAA02' @{pack='site';surface='app';destructive=$true;related=@('pmt-b0000001')}
    Write-S2Catalog @($a,$b)
    $c2=Read-SBWorkflowCatalog $s2Root
    Assert-Prompts ($c2.schemaVersion -eq 2 -and $c2.prompts.Count -eq 2) '#566: a schema 2 catalog loads'
    Assert-Prompts ($c2.prompts[1].pack -eq 'site' -and $c2.prompts[1].surface -eq 'app' -and $c2.prompts[1].destructive) '#566: pack, surface and destructive are read'
    Assert-Prompts ((Resolve-SBWorkflowPrompt $c2 'stop').via -eq 'role' -and (Resolve-SBWorkflowPrompt $c2 'stop').prompt.code -eq 'AAA01') '#566: a role resolves to its card'
    Assert-Prompts ((Resolve-SBWorkflowPrompt $c2 'pmt-b0000002').via -eq 'id' -and (Resolve-SBWorkflowPrompt $c2 'AAA02').via -eq 'code') '#566: ID and code still resolve'
    Assert-Prompts (@($c2.prompts[0].related).Count -eq 0) '#566: related is optional in schema 2'
    Assert-Prompts ($catalog.prompts[0].pack -eq 'core' -and $catalog.prompts[0].surface -eq 'chat' -and $catalog.prompts[0].destructive -is [bool]) '#566: schema 1 cards load with core, chat and destructive defaults'
    Write-S2Catalog @($a,(New-S2Card 'pmt-b0000002' 'AAA02' @{destructive=$null}))
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.catalog.invalid' '#566: destructive is required in schema 2'
    Write-S2Catalog @($a,(New-S2Card 'pmt-b0000002' 'AAA02' @{pack='misc'}))
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.catalog.invalid' '#566: an unknown pack is refused'
    Write-S2Catalog @($a,(New-S2Card 'pmt-b0000002' 'AAA02' @{scope='repo'}))
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.catalog.invalid' '#566: scope is dropped in schema 2'
    Write-S2Catalog @($a,(New-S2Card 'pmt-b0000002' 'AAA02' @{role='stop'}))
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.role.conflict' '#566: a role on two cards is refused'
    Write-S2Catalog @($a,(New-S2Card 'pmt-b0000002' 'AAA02' @{role='Bad Role'}))
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.catalog.invalid' '#566: a malformed role is refused'
    Write-S2Catalog @($a,$b) 3
    Assert-S2Refused {Read-SBWorkflowCatalog $s2Root} 'prompts.catalog.invalid' '#566: an unknown schema version is refused'
    Write-S2Catalog @($a,$b)
    $c2=Read-SBWorkflowCatalog $s2Root
    Assert-Prompts (@((Read-SBPromptAliases $s2Root $c2).aliases).Count -eq 0) '#566: a missing alias table is empty'
    Write-S2 'direttive/prompts/aliases.json' '{"schemaVersion":1,"aliases":[{"code":"OLD01","status":"renamed","ids":["pmt-b0000001"]},{"code":"OLD02","status":"split","ids":["pmt-b0000001","pmt-b0000002"]},{"code":"OLD03","status":"retired"}]}'
    Assert-Prompts (@((Read-SBPromptAliases $s2Root $c2).aliases).Count -eq 3) '#566: a valid alias table loads'
    Write-S2 'direttive/prompts/aliases.json' '{"schemaVersion":1,"aliases":[{"code":"AAA01","status":"renamed","ids":["pmt-b0000002"]}]}'
    Assert-S2Refused {Read-SBPromptAliases $s2Root $c2} 'prompts.alias.invalid' '#566: an alias never reuses an active code'
    Write-S2 'direttive/prompts/aliases.json' '{"schemaVersion":1,"aliases":[{"code":"OLD01","status":"renamed","ids":["pmt-ffffffff"]}]}'
    Assert-S2Refused {Read-SBPromptAliases $s2Root $c2} 'prompts.alias.invalid' '#566: an alias target must exist'
    Write-S2 'direttive/prompts/aliases.json' '{"schemaVersion":1,"aliases":[{"code":"OLD01","status":"split","ids":["pmt-b0000001"]}]}'
    Assert-S2Refused {Read-SBPromptAliases $s2Root $c2} 'prompts.alias.invalid' '#566: a split needs at least two successors'
    Write-S2 'direttive/prompts/workflows/core.json' (($flowHead -replace '"status":"active",','"status":"active","pack":"site",')+'{"step":"first","ref":"pmt-b0000001","kind":"required","gate":"auto"},{"step":"pick","ref":"pmt-b0000001","kind":"choice","gate":"confirm","choices":["pmt-b0000001","pmt-b0000002"]}]}')
    Assert-Prompts (@(Read-SBPromptWorkflows $s2Root $c2).Count -eq 1) '#566: a valid workflow loads'
    Write-S2 'direttive/prompts/aliases.json' '{"schemaVersion":1,"aliases":[{"code":"OLD01","status":"workflow","workflow":"wfl-c0000001"}]}'
    Assert-Prompts (@((Read-SBPromptAliases $s2Root $c2 @(Read-SBPromptWorkflows $s2Root $c2)).aliases).Count -eq 1) '#566: an alias can point to a workflow'
    Write-S2 'direttive/prompts/workflows/core.json' ($flowHead+'{"step":"first","ref":"pmt-b0000009","kind":"required","gate":"auto"}]}')
    Assert-S2Refused {Read-SBPromptWorkflows $s2Root $c2} 'prompts.workflow.step' '#566: a workflow step must cite an existing card'
    Write-S2 'direttive/prompts/workflows/core.json' ($flowHead+'{"step":"first","ref":"pmt-b0000002","kind":"required","gate":"auto"}]}')
    Assert-S2Refused {Read-SBPromptWorkflows $s2Root $c2} 'prompts.workflow.pack' '#566: a core workflow cannot use a site card'
    Write-S2 'direttive/prompts/workflows/core.json' ($flowHead+'{"step":"first","ref":"pmt-b0000001","kind":"required","gate":"auto"},{"step":"first","ref":"pmt-b0000001","kind":"optional","gate":"auto"}]}')
    Assert-S2Refused {Read-SBPromptWorkflows $s2Root $c2} 'prompts.workflow.invalid' '#566: duplicate step names are refused'
    Write-S2 'direttive/prompts/workflows/core.json' (($flowHead+'{"step":"first","ref":"pmt-b0000001","kind":"required","gate":"auto"}]}') -replace '"wf-core"','"core"')
    Assert-S2Refused {Read-SBPromptWorkflows $s2Root $c2} 'prompts.workflow.invalid' '#566: a workflow key must start with wf-'
}finally{
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $s2Root)){Remove-Item -LiteralPath $s2Root -Recurse -Force}
}
# #568: migration tool on a copy of the real catalog and cards; the real repository is never written.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptMigration.psm1') -Force
$migRoot=Join-Path (Get-SBTestRoot) ('migration-'+[guid]::NewGuid().ToString('N').Substring(0,12))
try{
    [IO.Directory]::CreateDirectory((Join-Path $migRoot 'config'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $brain 'direttive') -Destination (Join-Path $migRoot 'direttive') -Recurse
    Copy-Item -Path (Join-Path $brain 'config/prompt-*.json') -Destination (Join-Path $migRoot 'config')
    $migCatalogPath=Join-Path $migRoot 'direttive/prompts/catalog.json'
    $migRaw=Read-SBText $migCatalogPath
    Assert-Prompts ((ConvertTo-SBPromptJson (ConvertFrom-Json -InputObject $migRaw -AsHashtable))+"`n" -ceq $migRaw.Replace("`r`n","`n")) '#568: the catalog serializer round-trips the catalog byte for byte'
    $plan=Get-SBPromptMigrationPlan $migRoot
    $map=Read-SBPromptMigrationMap $migRoot
    Assert-Prompts (@($plan.rows).Count -eq 121 -and @($plan.rows|Where-Object {$_.outcome -in 'keep','split','workflow' -and $_.action -in 'rename','retire'}).Count -eq 121) '#568: the dry run lists 121 old codes, each with one outcome'
    Assert-Prompts (@($plan.rows.oldCode|Select-Object -Unique).Count -eq 121 -and !(@($plan.rows|Where-Object {$_.oldCode -notin $map.cards.oldCode}).Count)) '#568: every old code of the map appears once'
    Assert-Prompts (@($plan.rows|Where-Object {$_.idFate -eq 'retired'}).Count -eq 4 -and @($plan.rows|Where-Object {$_.idFate -eq 'kept'}).Count -eq 117 -and !(@($plan.rows|Where-Object {!$_.oldId}).Count)) '#568: every old card ID is kept (117) or listed as retired (4)'
    Assert-Prompts ($plan.unmapped -contains 'SYS18') '#568: a catalog card outside the map is reported, not touched'
    Assert-Prompts ((Read-SBText $migCatalogPath) -ceq $migRaw) '#568: the dry run writes nothing'
    $before=@{}; foreach($row in $plan.rows){if($row.pending){$before[$row.oldCode]=(Read-SBWorkflowCatalog $migRoot).prompts|Where-Object code -eq $row.oldCode|ForEach-Object id}}
    $writer={param($path,$text) [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))}
    $mover={param($from,$to) Move-Item -LiteralPath $from -Destination $to}
    $remover={param($path) Remove-Item -LiteralPath $path}
    Invoke-SBPromptMigration $plan $writer $mover $remover
    $after=Read-SBWorkflowCatalog $migRoot -ValidateBodies
    $afterIds=@($after.prompts.id)
    $lost=@($plan.rows|Where-Object {$_.idFate -eq 'kept' -and $_.oldId -notin $afterIds})
    Assert-Prompts (!$lost.Count) '#568: every kept card ID is still in the catalog under its new code'
    Assert-Prompts (@($after.prompts|Where-Object {$_.code -in $plan.rows.oldCode}).Count -eq 0) '#568: no old code remains in the catalog'
    $aliases=Read-SBPromptAliases $migRoot $after
    Assert-Prompts (@($aliases.aliases).Count -eq 121 -and @($aliases.aliases|Where-Object {$_.status -eq 'retired' -and $_.retiredId}).Count -eq 4) '#568: aliases.json has 121 entries and lists the 4 retired IDs'
    Assert-Prompts ($aliases.aliases|Where-Object {$_.code -eq 'AIS01'}|ForEach-Object {$_.status -eq 'renamed' -and $_.ids[0] -eq $before['AIS01']}) '#568: an old code resolves to the same card ID'
    foreach($row in $plan.rows|Where-Object action -eq 'rename'){
        if(!(Test-Path -LiteralPath (Join-Path $migRoot ('direttive/prompts/'+$row.newCode+'.md'))) -or (Test-Path -LiteralPath (Join-Path $migRoot ('direttive/prompts/'+$row.oldCode+'.md')))){Assert-Prompts $false ('#568: card files moved for '+$row.oldCode)}
    }
    Assert-Prompts $true '#568: every renamed card has its new file and no old file'
    $again=Get-SBPromptMigrationPlan $migRoot
    Assert-Prompts ($again.changeCount -eq 0 -and @($again.rows|Where-Object pending).Count -eq 0) '#568: a second run changes nothing'
    $afterRaw=Read-SBText $migCatalogPath
    Invoke-SBPromptMigration $again $writer $mover $remover
    Assert-Prompts ((Read-SBText $migCatalogPath) -ceq $afterRaw) '#568: the second run leaves the catalog identical'
}finally{
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $migRoot)){Remove-Item -LiteralPath $migRoot -Recurse -Force}
}
# #615: validated card lifecycle on a copy of the real catalog; the real repository is never written.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptLifecycle.psm1') -Force
$lcRoot=Join-Path (Get-SBTestRoot) ('lifecycle-'+[guid]::NewGuid().ToString('N').Substring(0,12))
try{
    [IO.Directory]::CreateDirectory((Join-Path $lcRoot 'config'))|Out-Null
    Copy-Item -LiteralPath (Join-Path $brain 'direttive') -Destination (Join-Path $lcRoot 'direttive') -Recurse
    Copy-Item -Path (Join-Path $brain 'config/prompt-*.json') -Destination (Join-Path $lcRoot 'config')
    $lcCatalogPath=Join-Path $lcRoot 'direttive/prompts/catalog.json'
    $lcRaw=Read-SBText $lcCatalogPath
    $lcWrite={param($path,$text) [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null;[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))}
    $lcRemove={param($path) Remove-Item -LiteralPath $path}
    $lcCatalog=Read-SBWorkflowCatalog $lcRoot
    $first=$lcCatalog.prompts|Where-Object {$_.related.Count -and -not $_.ContainsKey('role')}|Select-Object -First 1
    # Retire: refused while referenced, names the references, writes nothing.
    $refused=Get-SBPromptLifecyclePlan $lcRoot 'retire' @{Code=$first.code}
    Assert-Prompts (!$refused.valid -and ($refused.errors -join ' ') -match [regex]::Escape($first.code) -and ($refused.errors -join ' ') -match 'referenced by card ') '#615: retiring a referenced card is refused and names the referencing cards'
    Assert-Prompts (!$refused.changeCount -and (Read-SBText $lcCatalogPath) -ceq $lcRaw) '#615: a refused retire plans and writes nothing'
    $withRole=$lcCatalog.prompts|Where-Object {$_.ContainsKey('role')}|Select-Object -First 1
    Assert-Prompts (!(Get-SBPromptLifecyclePlan $lcRoot 'retire' @{Code=$withRole.code}).valid) '#615: retiring a card that holds a role is refused'
    # Add: preview validates, then applies; the code is never reused afterwards.
    $addBody=Join-Path $lcRoot 'new-en.md'
    $template=(Read-SBText (Join-Path $lcRoot ('direttive/prompts/'+$first.file))).Replace("`r`n","`n")
    # Bodies cite no other cards, so the new card needs no related entries beyond the required one.
    $uncited={param($text) [regex]::Replace($text.Replace("`r`n","`n"),'\b[A-Z]{3}\d{2}\b','the card')}
    [IO.File]::WriteAllText($addBody,(& $uncited $template),[Text.UTF8Encoding]::new($false))
    $addOptions=@{Code='ZZZ91';Category=$first.category;Summary='Lifecycle test card.';Target=$first.target;Mode=$first.mode;Scope=$first.scope;Requires='nothing';Example='lifecycle test';Related=@($first.code);BodyPath=$addBody}
    $dupCodeOptions=$addOptions.Clone(); $dupCodeOptions.Code=$first.code
    $badAdd=Get-SBPromptLifecyclePlan $lcRoot 'add' $dupCodeOptions
    Assert-Prompts (!$badAdd.valid -and ($badAdd.errors -join ' ') -match 'already in the catalog') '#615: add refuses an existing code'
    $badRelatedOptions=$addOptions.Clone(); $badRelatedOptions.Related=@('NOPE99')
    $badRelated=Get-SBPromptLifecyclePlan $lcRoot 'add' $badRelatedOptions
    Assert-Prompts (!$badRelated.valid) '#615: add refuses a related card that does not exist'
    $missing=Get-SBPromptLifecyclePlan $lcRoot 'add' @{Code='ZZZ91'}
    Assert-Prompts (!$missing.valid -and $missing.errors.Count -ge 3) '#615: add refuses missing fields and bodies'
    $addPlan=Get-SBPromptLifecyclePlan $lcRoot 'add' $addOptions
    Assert-Prompts ($addPlan.valid -and $addPlan.changeCount -eq 2 -and (Read-SBText $lcCatalogPath) -ceq $lcRaw) '#615: add previews two file changes and writes nothing'
    Invoke-SBPromptLifecycle $lcRoot $addPlan $lcWrite $lcRemove
    $afterAdd=Read-SBWorkflowCatalog $lcRoot -ValidateBodies -ValidateReferences
    $added=@($afterAdd.prompts|Where-Object code -ceq 'ZZZ91')[0]
    Assert-Prompts ($added -and $added.id -match '^pmt-[0-9a-f]{8}$' -and $first.id -in $added.related) '#615: an applied add gives the card a new immutable ID and valid related'
    # Edit: summary changes follow into the card header; the code and ID stay.
    $editPlan=Get-SBPromptLifecyclePlan $lcRoot 'edit' @{Code='ZZZ91';Fields=@{summary='Edited lifecycle card.'}}
    Assert-Prompts ($editPlan.valid -and $editPlan.changeCount -eq 2) '#615: edit previews the catalog and the card header'
    Invoke-SBPromptLifecycle $lcRoot $editPlan $lcWrite $lcRemove
    $afterEdit=Read-SBWorkflowCatalog $lcRoot -ValidateBodies
    $edited=@($afterEdit.prompts|Where-Object code -ceq 'ZZZ91')[0]
    Assert-Prompts ($edited.id -ceq $added.id -and $edited.summary -ceq 'Edited lifecycle card.') '#615: an applied edit keeps the ID and updates the summary'
    Assert-Prompts (!(Get-SBPromptLifecyclePlan $lcRoot 'edit' @{Code='ZZZ91';Fields=@{summary=('x'*90)}}).valid) '#615: edit refuses an invalid value'
    # Duplicate: new ID, role not copied, bodies copied with the new header.
    $dupPlan=Get-SBPromptLifecyclePlan $lcRoot 'duplicate' @{Code='ZZZ91';NewCode='ZZZ92';Summary='Duplicated lifecycle card.'}
    Assert-Prompts ($dupPlan.valid -and $dupPlan.changeCount -eq 2) '#615: duplicate previews two file changes'
    Assert-Prompts (!(Get-SBPromptLifecyclePlan $lcRoot 'duplicate' @{Code='ZZZ91';NewCode='ZZZ91'}).valid) '#615: duplicate refuses an existing code'
    Invoke-SBPromptLifecycle $lcRoot $dupPlan $lcWrite $lcRemove
    $afterDup=Read-SBWorkflowCatalog $lcRoot -ValidateBodies
    $dup=@($afterDup.prompts|Where-Object code -ceq 'ZZZ92')[0]
    Assert-Prompts ($dup -and $dup.id -cne $added.id -and $added.id -in $dup.related) '#615: an applied duplicate has its own ID and relates to the source'
    # Deprecate: warns on resolve, requires a reason and a valid successor.
    Assert-Prompts (!(Get-SBPromptLifecyclePlan $lcRoot 'deprecate' @{Code='ZZZ92'}).valid) '#615: deprecate needs a reason'
    Assert-Prompts (!(Get-SBPromptLifecyclePlan $lcRoot 'deprecate' @{Code='ZZZ92';Reason='r';Successor='ZZZ92'}).valid) '#615: a card cannot succeed itself'
    $depPlan=Get-SBPromptLifecyclePlan $lcRoot 'deprecate' @{Code='ZZZ92';Reason='Superseded by the source card.';Successor='ZZZ91'}
    Assert-Prompts ($depPlan.valid -and $depPlan.changeCount -eq 1) '#615: deprecate previews one catalog change'
    Invoke-SBPromptLifecycle $lcRoot $depPlan $lcWrite $lcRemove
    $afterDep=Read-SBWorkflowCatalog $lcRoot -ValidateBodies
    $resolved=Resolve-SBWorkflowPrompt $afterDep 'ZZZ92'
    Assert-Prompts ($resolved.warning -match 'deprecated' -and !(Get-SBPromptLifecyclePlan $lcRoot 'deprecate' @{Code='ZZZ92';Reason='again'}).valid) '#615: a deprecated card warns when selected and cannot be deprecated twice'
    # Retire: the duplicate has no inbound references (it only points out), so it retires with an alias and its ID is never reused.
    $retire=Get-SBPromptLifecyclePlan $lcRoot 'retire' @{Code='ZZZ92'}
    Assert-Prompts ($retire.valid -and $retire.removals.Count -eq 1) '#615: retiring an unreferenced card previews the file removal and the alias'
    Invoke-SBPromptLifecycle $lcRoot $retire $lcWrite $lcRemove
    $afterRetire=Read-SBWorkflowCatalog $lcRoot -ValidateBodies
    $aliasTable=Read-SBPromptAliases $lcRoot $afterRetire
    Assert-Prompts (!@($afterRetire.prompts|Where-Object code -ceq 'ZZZ92').Count -and @($aliasTable.aliases|Where-Object {$_.code -ceq 'ZZZ92' -and $_.status -eq 'retired' -and $_.retiredId -ceq $dup.id}).Count -eq 1) '#615: a retired card leaves the catalog and its ID is recorded in aliases.json'
    $reuse=Get-SBPromptLifecyclePlan $lcRoot 'duplicate' @{Code='ZZZ91';NewCode='ZZZ92'}
    Assert-Prompts (!$reuse.valid -and ($reuse.errors -join ' ') -match 'never reused') '#615: a retired code is never reused'
    # A workflow step blocks retirement and is named.
    $flowDir=Join-Path $lcRoot 'direttive/prompts/workflows'; [IO.Directory]::CreateDirectory($flowDir)|Out-Null
    [IO.File]::WriteAllText((Join-Path $flowDir 'lifecycle.json'),('{"schemaVersion":1,"id":"wfl-00000615","key":"wf-lifecycle","title":"Lifecycle","revision":1,"status":"active","steps":[{"step":"only","ref":"'+$edited.id+'","kind":"required","gate":"auto"}]}'),[Text.UTF8Encoding]::new($false))
    # The workflow cites the card; related lists still name it too, so remove those with a related edit first.
    $flowRefusal=Get-SBPromptLifecyclePlan $lcRoot 'retire' @{Code='ZZZ91'}
    Assert-Prompts (!$flowRefusal.valid -and ($flowRefusal.errors -join ' ') -match 'workflow wf-lifecycle \(step only\)') '#615: retiring a card used by a workflow is refused and names the workflow step'
    $deprecatedBefore=Get-SBPromptLifecyclePlan $lcRoot 'deprecate' @{Code='ZZZ91';Reason='Planned removal.'}
    Assert-Prompts ($deprecatedBefore.valid -and ($deprecatedBefore.notes -join ' ') -match 'wf-lifecycle') '#615: deprecating a card used by a workflow succeeds and lists the workflow as a note'
    Assert-Prompts ((Read-SBText $lcCatalogPath) -cne $lcRaw -and (Read-SBText (Join-Path $brain 'direttive/prompts/catalog.json')) -ceq $lcRaw) '#615: only the copy changed, never the real catalog'
}finally{
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $lcRoot)){Remove-Item -LiteralPath $lcRoot -Recurse -Force}
}
'SUCCESS PROMPTS: '+$script:promptChecks+' verifiche'
