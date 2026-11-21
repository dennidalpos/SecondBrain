#requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Sources.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Resources.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$passed=0
function Assert-Res($Value,[string]$Message){if(!$Value){throw "FAIL RESOURCES: $Message"};$script:passed++;"PASS RESOURCES: $Message"}
function Set-Res([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$root=Join-Path (Get-SBTestRoot) ('secondbrain-resources-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
foreach($name in @('source.schema.json','source-applicability.schema.json')){Set-Res (Join-Path $root ('config/'+$name)) (Read-SBText (Join-Path $PSScriptRoot ('../config/'+$name)))}
$registryPath=Join-Path $root 'shared/authoritative-sources'
Set-Res (Join-Path $registryPath 'entity.json') (ConvertTo-SBJson @{id='resource-authoritative-sources';kind='resource';schemaVersion=1;status='active';title='Fonti'})
Set-Res (Join-Path $registryPath 'brief.md') "brief`n"
Set-Res (Join-Path $registryPath 'domains.json') (ConvertTo-SBJson @{schemaVersion=1;domains=@(@{id='privacy';title='Privacy'})})
Set-Res (Join-Path $root 'shared/notes/entity.json') (ConvertTo-SBJson @{id='resource-notes';kind='resource';schemaVersion=1;status='active';title='Notes'})
Set-Res (Join-Path $root 'shared/notes/brief.md') "brief`n"
Set-Res (Join-Path $root 'shared/orphan/readme.txt') "no entity metadata`n"
$config=@{brainRoot=$root;runtimeRoot=(Join-Path $root 'runtime');backupRoot=(Join-Path $root 'backup');configPath=(Join-Path $root '.runtime/hosts/fixture/workstation.json')}
function New-Card([string]$Id,[string]$OfficialId,[string]$Kind,$Related){
    @{schemaVersion=1;id=$Id;title=$Id;kind=$Kind;issuer='Fixture';domains=@('privacy');jurisdictions=@('EU');language='it';officialId=$OfficialId;edition='v1';publicationDate=$null;rights=@{status='public-reusable';reference='https://example.com/license';notes='Fixture'};endpoints=@(@{id='canonical';url='https://example.com/'+$Id;format='html';role='canonical';allowedHosts=@('example.com');expectedText='Articolo'});versions=@();acceptedVersion=$null;relatedSources=@($Related);effectiveDates=@(@{provision='Entrata in vigore';date=$null;status='requires-verification';reference='Fixture'});notes=@()}
}
Set-Res (Join-Path $registryPath 'entries/law-a/metadata.json') (ConvertTo-SBJson (New-Card 'law-a' 'Regolamento (UE) 2016/679' 'regulation' @()))
Set-Res (Join-Path $registryPath 'entries/law-b/metadata.json') (ConvertTo-SBJson (New-Card 'law-b' 'Regolamento (UE) 2022/2065' 'regulation' @(@{id='law-a';relation='related'})))
$registry=Read-SBSourceRegistry $root
# Layout, control files and index
$folders=@(Get-SBResourceFolders $root)
Assert-Res ($folders.Count -eq 3) 'cartelle risorsa elencate (autoritative-sources, notes, orphan)'
$issues=@(Get-SBResourceChecks $root)
Assert-Res (@($issues|Where-Object kind -eq 'layout-missing').Count -eq 2) 'missing entity.json and brief.md reported'
Assert-Res (@($issues|Where-Object kind -eq 'control-missing').Count -eq 3) 'missing CONTROL.json reported'
$written=@(Update-SBResourceViews $config)
Assert-Res ($written.Count -eq 6) 'CONTROL.json and INDEX.md written for each resource'
Assert-Res (@(Update-SBResourceViews $config).Count -eq 0) 'aggiornamento idempotente'
Assert-Res (@(Get-SBResourceChecks $root|Where-Object kind -in @('control-missing','control-drift','index-drift')).Count -eq 0) 'controllo coerente dopo l aggiornamento'
$control=Read-SBJson (Join-Path $registryPath 'CONTROL.json') $null
Assert-Res (@($control.files|Where-Object path -eq 'CONTROL.json').Count -eq 0) 'CONTROL.json does not include itself'
Set-Res (Join-Path $registryPath 'brief.md') "modified`n"
Assert-Res (@(Get-SBResourceChecks $root|Where-Object {$_.kind -eq 'control-drift' -and $_.resource -eq 'authoritative-sources' -and $_.changed -eq 1}).Count -eq 1) 'modifica di un file rilevata dal controllo'
# Sync: collect, preservation, closure
$script:html='<html><body>Articolo 1. Vedi anche il regolamento 2016/679 e la direttiva 2099/12.</body></html>'
$transport={param($ep) @{bytes=[Text.Encoding]::UTF8.GetBytes($script:html+$ep.url);finalUrl=$ep.url;httpStatus=200;contentType='text/html';etag='';lastModified=''}}
$result=Invoke-SBResourceSync $config $registry $null 3 10 $transport
Assert-Res ($result.complete -and @($result.collected).Count -eq 2) 'Sync collects sources without a baseline as candidates'
$registry=Read-SBSourceRegistry $root
Assert-Res (@($registry.sources|ForEach-Object {$_.versions}).Count -eq 2 -and !@($registry.sources|Where-Object acceptedVersion).Count) 'candidate versions, none accepted automatically'
# No converter in the fixture: provide transcripts so that reference detection has text to read.
foreach($source in $registry.sources){
    $versionRoot=Join-Path $source._root ('versions/'+$source.versions[0].id)
    Set-Res (Join-Path $versionRoot 'transcript.md') 'Articolo 1. Vedi anche il regolamento 2016/679 e la direttiva 2099/12.'
    $manifest=Read-SBJson (Join-Path $versionRoot 'manifest.json') $null
    $manifest.transcription.path='transcript.md'
    Set-Res (Join-Path $versionRoot 'manifest.json') (ConvertTo-SBJson $manifest)
}
$registry=Read-SBSourceRegistry $root
$firstVersions=@($registry.sources|ForEach-Object {$_.versions[0].id})
$again=Invoke-SBResourceSync $config $registry $null 3 10 $transport
Assert-Res (@($again.collected).Count -eq 0) 'second synchronization without changes creates no versions'
$script:html=$script:html.Replace('Articolo 1.','Articolo 1 bis.')
$registry=Read-SBSourceRegistry $root
$changed=Invoke-SBResourceSync $config $registry $null 3 10 $transport
$registry=Read-SBSourceRegistry $root
Assert-Res (@($changed.collected).Count -eq 2 -and @($registry.sources|ForEach-Object {$_.versions}).Count -eq 4) 'a change in a source creates a new version'
foreach($id in $firstVersions){Assert-Res (@($registry.sources|ForEach-Object {$_.versions}|Where-Object id -ceq $id).Count -eq 1) ('versione precedente preservata '+$id)}
$queue=Read-SBJson (Join-Path $registryPath 'normative-queue.json') $null
Assert-Res (@($queue.items|Where-Object {$_.kind -eq 'unresolved-reference' -and $_.reference -eq '2099/12'}).Count -ge 1) 'unresolved reference put in the review queue'
$a=@($registry.sources|Where-Object id -eq 'law-b')[0]
$refs=Find-SBSourceReferences $registry $a
Assert-Res ('law-a' -in $refs.resolved) 'reference resolved to a registry card'
$closure=Get-SBSourceClosure $registry @('law-b') 3 10
Assert-Res ('law-a' -in $closure.sources -and 'law-b' -in $closure.sources) 'chiusura segue relatedSources'
$limited=Get-SBSourceClosure $registry @('law-b') 3 1
Assert-Res ($limited.sources.Count -eq 1 -and @($limited.queue|Where-Object kind -eq 'limit-reached').Count -ge 1) 'source limit recorded in the queue'
Assert-Res (!(Test-SBResourceStale $config) ) 'report recente non e obsoleto'
Assert-Res (@(Get-SBResourceChecks $root|Where-Object kind -in @('control-missing','control-drift','index-drift')).Count -eq 0) 'viste coerenti dopo Sync'
# #438: ELI, CELEX, Official Journal and Gazzetta Ufficiale citations in synthetic transcripts
$sample=@'
Vedi https://data.europa.eu/eli/reg/2016/679/oj e la eli/dir/2016/680/oj, nonche eli/id/2003/06/30/003G0218/sg.
CELEX 32016L0680; bare 32014R0910; celex:32016r0679; lista 32022R2065-20240101 e 12016E007 non e un atto.
GU L 119 del 4.5.2016 e OJ L 119, 4.5.2016 sono la stessa Gazzetta europea.
Gazzetta Ufficiale n. 174 del 29 luglio 2003, G.U. n. 174 del 29/07/2003, Gazzetta Ufficiale della Repubblica italiana, Serie Generale n. 5 del 8 gennaio 2021 e GU 15 marzo 2019, n. 63.
Data impossibile: GU n. 3 del 31 febbraio 2020. Date comuni 12/05/2020 e numeri 2099/12; decreto n. 196 del 30 giugno 2003.
'@
$cited=@(Get-SBTextReferences $sample)
$names=@($cited|ForEach-Object {$_.reference})
Assert-Res ((@('eli/reg/2016/679','eli/dir/2016/680','eli/id/2003/06/30/003G0218')|Where-Object {$_ -notin $names}).Count -eq 0) 'ELI europei e italiano riconosciuti'
Assert-Res ((@('CELEX:32016L0680','CELEX:32014R0910','CELEX:32016R0679','CELEX:32022R2065')|Where-Object {$_ -notin $names}).Count -eq 0) 'CELEX with and without prefix, also lowercase and consolidated, recognized'
Assert-Res ('CELEX:12016E007' -notin $names -and !@($names|Where-Object {$_ -like 'CELEX:1201*'}).Count) 'primary law with a three-digit number is not a CELEX'
Assert-Res (@($names|Where-Object {$_ -eq 'OJ L 119, 04.05.2016'}).Count -eq 1) 'Gazzetta europea riconosciuta nelle due grafie e normalizzata una volta'
Assert-Res ((@('GU n. 174 del 29.07.2003','GU n. 5 del 08.01.2021','GU n. 63 del 15.03.2019')|Where-Object {$_ -notin $names}).Count -eq 0) 'citazioni GU con mese in lettere, data numerica e ordine inverso'
Assert-Res (@($names|Where-Object {$_ -eq 'GU n. 174 del 29.07.2003'}).Count -eq 1) 'same GU in two spellings normalized once'
Assert-Res (!@($names|Where-Object {$_ -like 'GU n. 3 *'})) 'GU con data impossibile scartata'
Assert-Res (!@($names|Where-Object {$_ -in @('174/2003','2003/174','2016/679','2016/680','2003/6')})) 'le citazioni strutturate non producono numeri spuri'
Assert-Res ('2099/12' -in $names -and '2003/196' -in $names -and !($names -contains '12/05')) 'official numbers detected as before and common dates ignored'
Assert-Res (@($cited|Where-Object {$_.reference -eq 'eli/reg/2016/679'})[0].ids -contains 'n:2016/679') 'ELI europeo equivale al numero ufficiale'
Assert-Res (@(Get-SBTextReferences 'https://eur-lex.europa.eu/legal-content/IT/TXT/?uri=CELEX:32016R0679 e 2016/679' -StructuredOnly).Count -eq 1) 'StructuredOnly ignora i numeri semplici'
# Resolution against the registry (by official number, ELI or CELEX) and queue of the rest
$lawB=@($registry.sources|Where-Object id -eq 'law-b')[0]
$versionB=@($lawB.versions|Sort-Object id)[-1]
$rootB=Join-Path $lawB._root ('versions/'+$versionB.id)
Set-Res (Join-Path $rootB 'transcript.md') 'Vedi CELEX:32016R0679, eli/reg/2016/679/oj, CELEX:32022R2065 (questo stesso atto), eli/dir/2016/680/oj e Gazzetta Ufficiale n. 174 del 29 luglio 2003.'
$manifestB=Read-SBJson (Join-Path $rootB 'manifest.json') $null
$manifestB.transcription.path='transcript.md'
Set-Res (Join-Path $rootB 'manifest.json') (ConvertTo-SBJson $manifestB)
$registry=Read-SBSourceRegistry $root
$lawB=@($registry.sources|Where-Object id -eq 'law-b')[0]
$found=Find-SBSourceReferences $registry $lawB
Assert-Res ($found.resolved.Count -eq 1 -and 'law-a' -in $found.resolved) 'CELEX and ELI resolved on the registered card by official number'
Assert-Res ('CELEX:32022R2065' -notin $found.unresolved -and 'CELEX:32016R0679' -notin $found.unresolved) 'the self reference and the resolved ones do not end up in the queue'
Assert-Res ((@($found.unresolved|Sort-Object) -join '|') -eq 'eli/dir/2016/680|GU n. 174 del 29.07.2003') 'unregistered ELI and GU remain to be reviewed'
$closure=Get-SBSourceClosure $registry @('law-b') 3 10
Assert-Res (@($closure.queue|Where-Object {$_.kind -eq 'unresolved-reference' -and $_.referenceKind -eq 'eli' -and $_.reference -eq 'eli/dir/2016/680'}).Count -eq 1) 'la coda registra il tipo di riferimento'
# Card proposal: read-only, reference-only, nothing downloaded
Set-Res (Join-Path $registryPath 'normative-queue.json') (ConvertTo-SBJson @{schemaVersion=1;items=@($closure.queue)})
$hashBefore=Get-SBFileHash (Join-Path $registryPath 'normative-queue.json')
$proposals=Get-SBSourceCardProposals $registry $null $null
Assert-Res (@($proposals.proposals).Count -eq 3 -and !@($proposals.skipped).Count -and @($proposals.proposals|Where-Object {$_.reference -eq '2099/12' -and $_.card.id -eq 'ref-2099-12' -and $_.origin -eq 'law-a'}).Count -eq 1) 'one proposal for each reference in the queue, also numeric'
$eli=@($proposals.proposals|Where-Object reference -eq 'eli/dir/2016/680')[0]
Assert-Res ($eli.card.id -eq 'eu-dir-2016-680' -and $eli.card.kind -eq 'regulation' -and $eli.origin -eq 'law-b' -and 'EU' -in $eli.card.jurisdictions -and $eli.card.relatedSources[0].id -eq 'law-b') 'proposta ELI: id, tipo, origine e giurisdizione'
$gu=@($proposals.proposals|Where-Object reference -eq 'GU n. 174 del 29.07.2003')[0]
Assert-Res ($gu.card.id -eq 'it-gu-2003-07-29-n174' -and 'IT' -in $gu.card.jurisdictions) 'proposta GU: id e giurisdizione'
Assert-Res (!@($proposals.proposals|Where-Object {$_.card.rights.status -ne 'reference-only' -or $_.card.endpoints.Count -or $_.downloaded -or $_.card.acceptedVersion -or $_.card.versions.Count}).Count) 'the proposals are reference-only, without endpoints, versions or downloads'
Assert-Res ($eli.suggestedLocation -like 'https://eur-lex.europa.eu/*' -and !$gu.suggestedLocation) 'suggested address only as text, never as an endpoint'
Assert-Res ((Get-SBFileHash (Join-Path $registryPath 'normative-queue.json')) -ceq $hashBefore -and !(Test-Path -LiteralPath (Join-Path $registryPath 'entries/eu-dir-2016-680'))) 'the proposal writes nothing'
$known=Get-SBSourceCardProposals $registry 'CELEX:32016R0679' 'law-b'
Assert-Res (!@($known.proposals).Count -and @($known.registered)[0].sourceIds -contains 'law-a') 'reference already registered: no proposal, card indicated'
$single=Get-SBSourceCardProposals $registry 'eli/dir/2016/680/oj' $null
Assert-Res (@($single.proposals).Count -eq 1 -and $single.proposals[0].origin -eq 'law-b') 'riferimento singolo: origine ricavata dalla coda'
$threw=$false;try{Get-SBSourceCardProposals $registry 'nessun riferimento' 'law-b'|Out-Null}catch{$threw=$true}
Assert-Res $threw 'text without a reference rejected'
$threw=$false;try{Get-SBSourceCardProposals $registry 'eli/dir/2016/681/oj' $null|Out-Null}catch{$threw=$true}
Assert-Res $threw 'reference outside the queue without -SourceId rejected'
# Registering the proposal does not make it downloadable
$calls=0;$counting={param($ep) $script:calls++;@{bytes=[byte[]]@();finalUrl=$ep.url;httpStatus=200;contentType='text/html';etag='';lastModified=''}}
Set-Res (Join-Path $registryPath ('entries/'+$eli.card.id+'/metadata.json')) (ConvertTo-SBJson $eli.card)
$registry=Read-SBSourceRegistry $root
Assert-Res (@($registry.sources|Where-Object id -eq $eli.card.id).Count -eq 1) 'the proposed card is valid for the registry schema'
$threw=$false;try{Invoke-SBSourceCollect $config $registry $eli.card.id $null $counting|Out-Null}catch{$threw=$true}
Assert-Res ($threw -and $script:calls -eq 0) 'no download of a source with non-reusable rights'
$threw=$false;try{Invoke-SBSourceCollect $config $registry 'unregistered-law' $null $counting|Out-Null}catch{$threw=$true}
Assert-Res ($threw -and $script:calls -eq 0) 'no download of an unregistered source'
'SUCCESS RESOURCES: '+$passed+' verifiche'
