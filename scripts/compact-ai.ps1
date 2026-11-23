#requires -Version 7.5
<#
.SYNOPSIS
Model-assisted compaction of the dossier of the current repository with the light model of an agent CLI (roles.light of config/agent-models.json).
.DESCRIPTION
Mechanical tiering already runs at the end of every task and loses nothing; this command goes further by asking a cheap model to summarize
context.md and memory.md. The model runs read-only: it receives the dossier.compact card and both files and answers one JSON object
(config/analysis/compact.schema.json). The script builds the candidate (source hashes, open task ids, summaries) in a work folder and prints a preview:
sizes before and after, the essential context sections, the open decisions kept. Nothing in the dossier changes without -Apply, and -Apply
needs -ReviewNote: the text you wrote after reading the candidate. Applying archives the originals by hash (history/compaction) through
knowledge.ps1 -Compact -CandidatePath, so the originals stay consultable.
-ResultFile <json> reuses a model answer saved earlier (result.json of a previous run) instead of calling the model.
.EXAMPLE
pwsh -NoProfile -File scripts/compact-ai.ps1 -Provider claude
pwsh -NoProfile -File scripts/compact-ai.ps1 -Provider claude -Apply -ReviewNote 'Read the candidate: decisions and open issues kept'
#>
[CmdletBinding()]
param([ValidateSet('claude','codex','gemini')][string]$Provider,[string]$Model,[string]$Effort,[string]$CheckoutPath='.',
    [string]$ResultFile,[switch]$Apply,[string]$ReviewNote,[string]$CandidatePath,
    [ValidateRange(60,3600)][int]$TimeoutSeconds=900,[string]$ConfigPath,[string]$SessionId)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Knowledge.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
Add-SBMessages @{
    'compactai.provider' = @{ en = 'Give the provider with -Provider claude|codex|gemini (or -ResultFile with a saved answer)' }
    'compactai.repository' = @{ en = 'Working repository not resolvable: run from the managed checkout or give -CheckoutPath' }
    'compactai.review' = @{ en = '-Apply needs -ReviewNote: read the candidate first, then state what you checked' }
    'compactai.nocandidate' = @{ en = '-Apply needs the candidate of the preview: give -CandidatePath (printed by the preview) or run the preview again' }
    'compactai.essential' = @{ en = 'The summary of context.md lacks the required section(s): {0}. Run the preview again or pick a more capable model' }
    'compactai.result.invalid' = @{ en = 'The result file is not a compaction answer (context, memory, notes)' }
    'compactai.preview' = @{ en = 'Compaction candidate for {0} (model {1}, {2}): context.md {3} -> {4} characters, memory.md {5} -> {6} characters. Candidate: {7}' }
    'compactai.next' = @{ en = 'Nothing was changed. Read the candidate, then apply it with: sb compact ai -CandidatePath "{0}" -Apply -ReviewNote "<what you checked>"' }
    'compactai.applied' = @{ en = 'Compaction applied for {0}: originals archived in history/compaction and still readable with -Section and -Search.' }
}
$brain=(Get-SBBrainRootPath)
$config=Read-SBConfiguration $ConfigPath -ReadOnly
$repository=Resolve-SBWorkingRepository $CheckoutPath @($config.bindings)
if(!$repository){throw (New-SBError 'compactai.repository')}
$dossier=Join-Path $brain (Resolve-SBWorkingDossier $brain $repository)
$knowledge=Join-Path $PSScriptRoot 'knowledge.ps1'
$configArgs=if($ConfigPath){@('-ConfigPath',$ConfigPath)}else{@()}
$sessionArgs=if($SessionId){@('-SessionId',$SessionId)}else{@()}
$utf8=[Text.UTF8Encoding]::new($false)

if($Apply){
    if(!$ReviewNote -or !$ReviewNote.Trim()){throw (New-SBError 'compactai.review')}
    if(!$CandidatePath -or !(Test-Path -LiteralPath $CandidatePath -PathType Leaf)){throw (New-SBError 'compactai.nocandidate')}
    $candidate=Get-Content -Raw -Encoding utf8 $CandidatePath|ConvertFrom-Json -AsHashtable -Depth 40
    $candidate.reviewed=$true;$candidate.reviewNote=$ReviewNote.Trim()
    [IO.File]::WriteAllText($CandidatePath,(ConvertTo-SBJson $candidate),$utf8)
    & pwsh -NoProfile -File $knowledge -Compact -Dossier $dossier -CandidatePath $CandidatePath -Apply @configArgs @sessionArgs
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
    Get-SBMessage 'compactai.applied' @($repository)
    exit 0
}

$sources=[ordered]@{}
foreach($name in @('context.md','memory.md')){$sources[$name]=@{hash=(Get-SBFileHash (Join-Path $dossier $name));text=(Read-SBText (Join-Path $dossier $name))}}
$tracker=Resolve-SBTracker -BrainRoot $brain -Identity $repository -DossierPath $dossier -CheckoutPath $CheckoutPath -AllowedOwners @()
$openIds=@($tracker.data.tasks|Where-Object status -notin @('done','cancelled')|ForEach-Object {[string]$_.id})
$modelLabel='saved result';$effortLabel='-'
if($ResultFile){
    $saved=Get-Content -Raw -Encoding utf8 $ResultFile|ConvertFrom-Json -AsHashtable -Depth 40
    $answer=if($saved.ContainsKey('result')){$saved.result}else{$saved}
}else{
    if(!$Provider){throw (New-SBError 'compactai.provider')}
    $prompt=@(
        (Get-SBPromptCardText $brain 'dossier.compact'),'',
        '# Task for this session',
        "Repository: $repository. Summarize the two files below into a smaller context.md and memory.md, in the language of the originals. Keep every current decision, every open issue and the constraints; fold what is finished into short topic summaries. Context must keep the sections Constraints (or Vincoli), Current state (or Stato corrente), Open issues (or Problemi aperti) and Next step (or Prossimo passo) as `## ` headings. Do not invent facts and do not renew historical authorizations. The open tasks are: $($openIds -join ', ').",
        'Answer with the full text of both files in the fields context and memory, and short notes on what you folded.','',
        '## context.md',$sources['context.md'].text,'',
        '## memory.md',$sources['memory.md'].text
    ) -join "`n"
    $slug='compact'
    $workOut=(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'work.ps1') -Repository $repository -Category work -Slug $slug -Init -Task 'Model-assisted dossier compaction' -Client agent @configArgs @sessionArgs|Out-String)|ConvertFrom-Json -AsHashtable
    $outFolder=[string]$workOut.root
    $run=Invoke-SBAgentOneShot -Provider $Provider -Model $Model -Effort $Effort -Prompt $prompt -SchemaPath (Join-Path $brain 'config/analysis/compact.schema.json') -CheckoutPath ([IO.Path]::GetFullPath($CheckoutPath)) -OutputFolder $outFolder -BrainRoot $brain -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:([bool]$Model)
    $answer=$run.result;$modelLabel=$(if($run.model){$run.model}else{'CLI default'});$effortLabel=$(if($run.effort){'effort '+$run.effort}else{'default effort'})
}
if($answer -isnot [hashtable] -or !$answer.ContainsKey('context') -or !$answer.ContainsKey('memory')){throw (New-SBError 'compactai.result.invalid')}
$missing=@(Get-SBMissingContextSection ([string]$answer.context))
if($missing.Count){throw (New-SBError 'compactai.essential' @(($missing -join ', ')))}
$candidate=[ordered]@{schemaVersion=1;repository=$repository;sources=[ordered]@{'context.md'=$sources['context.md'].hash;'memory.md'=$sources['memory.md'].hash}
    summaries=[ordered]@{'context.md'=[string]$answer.context;'memory.md'=[string]$answer.memory};openTaskIds=$openIds;reviewed=$false;reviewNote='';notes=@($answer['notes'])}
if(!$ResultFile){$candidateFile=Join-Path $outFolder 'candidate.json'}else{$candidateFile=Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultFile))) 'candidate.json'}
[IO.File]::WriteAllText($candidateFile,(ConvertTo-SBJson $candidate),$utf8)
Get-SBMessage 'compactai.preview' @($repository,$modelLabel,$effortLabel,$sources['context.md'].text.Length,([string]$answer.context).Length,$sources['memory.md'].text.Length,([string]$answer.memory).Length,($candidateFile -replace '\\','/'))
foreach($note in @($answer['notes'])){'- '+$note}
Get-SBMessage 'compactai.next' @(($candidateFile -replace '\\','/'))
exit 0
