#requires -Version 7.5
# sb compact ai (scripts/compact-ai.ps1) on a synthetic dossier with a fake Claude Code CLI (#807): candidate, preview, refusal of -Apply without
# -ReviewNote, refusal of an answer without the essential sections, -Apply archiving the originals by hash, and a restore from history/compaction.
# No real model, dossier or IDE configuration is touched.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
$null=Enter-SBTestGitEnvironment
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:compactChecks=0
function Assert-Compact($Condition,[string]$Message){if(!$Condition){throw ('FAIL COMPACTAI: '+$Message)};$script:compactChecks++}
function Write-CompactFile([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$fixture=Join-Path (Get-SBTestRoot) ('compactai-'+[guid]::NewGuid().ToString('N'))
$brain=Join-Path $fixture 'brain'
$dossier=Join-Path $brain 'repos/Compact'
$checkout=Join-Path $fixture 'checkout'
$identity='github.com/test/compact'
$hostId=Get-SBHostId
$runtime=Get-SBStateRoot $brain $hostId
$configPath=Join-Path $runtime 'workstation.json'
function Invoke-CompactAi([string[]]$CliArguments){
    $lines=@(& pwsh -NoProfile -File (Join-Path $brain 'scripts/compact-ai.ps1') -ConfigPath $configPath -CheckoutPath $checkout @CliArguments 2>&1)
    @{code=$LASTEXITCODE;text=($lines|ForEach-Object {[string]$_}) -join "`n"}
}
$savedMode=$env:SB_FAKE_MODE
try{
    foreach($folder in @('scripts','config','directives')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$folder)) -Destination (Join-Path $brain $folder) -Recurse
    }
    Write-CompactFile (Join-Path $brain 'VERSION') (Read-SBText (Join-Path $PSScriptRoot '../VERSION'))
    Write-CompactFile (Join-Path $brain 'config/shared.json') (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
    Write-CompactFile (Join-Path $dossier 'entity.json') (ConvertTo-SBJson @{schemaVersion=1;id='compact-area';kind='area';title='Compact';status='active'})
    Write-CompactFile (Join-Path $dossier 'repository.json') (ConvertTo-SBJson @{schemaVersion=1;identity=$identity;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
    Write-CompactFile (Join-Path $dossier 'brief.md') '# Synthetic compact fixture'
    $originalContext="# Context`n`n## Current state`nLong history that the model folds. $('filler ' * 80)`n`n## Constraints`nKeep the decisions.`n`n## Open issues`nNone.`n`n## Next step`nVerify.`n"
    $originalMemory="# Memory`n`n- Decision: keep all data - Reason: recovery. $('detail ' * 80)`n"
    Write-CompactFile (Join-Path $dossier 'context.md') $originalContext
    Write-CompactFile (Join-Path $dossier 'memory.md') $originalMemory
    Write-CompactFile (Join-Path $dossier 'tracker.json') (ConvertTo-SBJson @{schemaVersion=1;repository=$identity;updatedAt=[DateTimeOffset]::UtcNow.ToString('o');tasks=@();history=@();extensions=@{lastSeq=0}})
    [IO.Directory]::CreateDirectory($checkout)|Out-Null
    & git -c core.longpaths=true -C $checkout init -q
    & git -c core.longpaths=true -C $checkout remote add origin 'https://github.com/test/compact.git'
    if($LASTEXITCODE){throw 'fixture git'}
    $cfg=@{schemaVersion=1;mode='portable';brainRoot=$brain;workstationId=$hostId;runtimeRoot=$runtime;backupRoot=(Join-Path $runtime 'backups');repositoryRoot=$brain;coordinationRoot=(Join-Path $brain '.runtime/access');bindings=@(@{identity=$identity;path=$checkout;remoteIdentity=$identity});ides=@();sessionTimeoutMinutes=30;lockWaitMs=60000;configPath=$configPath}
    Write-CompactFile $configPath (ConvertTo-SBJson $cfg)

    $help=@'
Usage: claude [options] [command] [prompt]
Options:
  --allowedTools, --allowed-tools <tools...>
      Comma or space-separated list of tool names to allow
  --disallowedTools, --disallowed-tools <tools...>
      Comma or space-separated list of tool names to deny
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --model <model>                       Model for the current session.
  --output-format <format>              Output format (only works with --print)
  --permission-mode <mode>              Permission mode to use for the session
  -p, --print                           Print response and exit
'@
    $fakeCli=Join-Path $fixture 'bin/claude.ps1'
    Write-CompactFile $fakeCli ("if(`$args -contains '--version'){'2.1.319 (Fake)';exit 0}`nif(`$args -contains '--help'){@'`n"+$help+"`n'@;exit 0}`n"+@'
$prompt=[Console]::In.ReadToEnd()
[IO.File]::WriteAllText((Join-Path $env:SB_FAKE_LOG 'prompt.txt'),$prompt)
if($env:SB_FAKE_MODE -eq 'noessential'){$context="# Context`n`nOnly a summary.`n"}
else{$context="# Context`n`n## Current state`nFolded summary.`n`n## Constraints`nKeep the decisions.`n`n## Open issues`nNone.`n`n## Next step`nVerify.`n"}
$answer=[ordered]@{context=$context;memory="# Memory`n`n- Decision: keep all data - Reason: recovery.`n";notes=@('folded the history into one paragraph')}
[ordered]@{type='result';is_error=$false;result=($answer|ConvertTo-Json -Compress)}|ConvertTo-Json -Compress
'@)
    $env:SB_FAKE_LOG=Join-Path $fixture 'fake-log';[IO.Directory]::CreateDirectory($env:SB_FAKE_LOG)|Out-Null

    # Preview: the fake agent runs read-only, the candidate carries the source hashes and nothing in the dossier changes.
    $env:SB_FAKE_MODE='valid'
    $contextHash=Get-SBFileHash (Join-Path $dossier 'context.md');$memoryHash=Get-SBFileHash (Join-Path $dossier 'memory.md')
    $preview=Invoke-CompactAi @('-Provider','claude','-AgentPath',$fakeCli)
    Assert-Compact ($preview.code -eq 0 -and $preview.text -match 'Compaction candidate for github.com/test/compact' -and $preview.text -match 'Nothing was changed') ('the preview prints sizes and the next step: '+$preview.text)
    Assert-Compact ((Read-SBText (Join-Path $env:SB_FAKE_LOG 'prompt.txt')) -match 'Summarize the two files below' -and (Read-SBText (Join-Path $env:SB_FAKE_LOG 'prompt.txt')) -match 'Long history that the model folds') 'the model receives the card, the task and both files'
    Assert-Compact ((Get-SBFileHash (Join-Path $dossier 'context.md')) -eq $contextHash -and (Get-SBFileHash (Join-Path $dossier 'memory.md')) -eq $memoryHash) 'the preview changes nothing in the dossier'
    $candidatePath=@(Get-ChildItem -LiteralPath $runtime -Recurse -Filter 'candidate.json' -File)[0].FullName
    $candidate=Read-SBText $candidatePath|ConvertFrom-Json -AsHashtable -Depth 40
    Assert-Compact ($candidate.sources['context.md'] -eq $contextHash -and $candidate.sources['memory.md'] -eq $memoryHash -and !$candidate.reviewed -and $candidate.summaries['context.md'] -match 'Folded summary') 'the candidate records the source hashes, the summaries and reviewed=false'

    # -Apply is refused without a review note and without a candidate, and does not touch the dossier.
    $noNote=Invoke-CompactAi @('-Apply','-CandidatePath',$candidatePath)
    Assert-Compact ($noNote.code -ne 0 -and $noNote.text -match '-ReviewNote' -and (Get-SBFileHash (Join-Path $dossier 'context.md')) -eq $contextHash) '-Apply without -ReviewNote is refused'
    $noCandidate=Invoke-CompactAi @('-Apply','-ReviewNote','read')
    Assert-Compact ($noCandidate.code -ne 0 -and $noCandidate.text -match 'CandidatePath') '-Apply without a candidate is refused'

    # An answer without the essential context sections is refused before any candidate is written.
    $env:SB_FAKE_MODE='noessential'
    $refused=Invoke-CompactAi @('-Provider','claude','-AgentPath',$fakeCli)
    Assert-Compact ($refused.code -ne 0 -and $refused.text -match 'required section') ('a summary without the essential sections is refused: '+$refused.text)

    # -Apply with a review note archives the originals by hash and replaces both files.
    $env:SB_FAKE_MODE='valid'
    $applied=Invoke-CompactAi @('-Apply','-CandidatePath',$candidatePath,'-ReviewNote','Read the candidate: constraints and decisions kept')
    Assert-Compact ($applied.code -eq 0 -and $applied.text -match 'Compaction applied') ('-Apply succeeds with a review note: '+$applied.text)
    Assert-Compact ((Read-SBText (Join-Path $dossier 'context.md')) -match 'Folded summary' -and (Read-SBText (Join-Path $dossier 'memory.md')).Length -lt $originalMemory.Length) 'context.md and memory.md hold the summaries'
    $archived=@(Get-ChildItem -LiteralPath (Join-Path $dossier 'history/compaction') -Recurse -File -ErrorAction SilentlyContinue)
    $originalCopy=@($archived|Where-Object {(Get-SBFileHash $_.FullName) -in @($contextHash,$memoryHash)})
    Assert-Compact ($originalCopy.Count -ge 2) ('the originals are archived by hash in history/compaction: '+(@($archived|ForEach-Object Name) -join ', '))

    # Rollback: restoring the archived originals gives back the exact bytes.
    foreach($copy in $originalCopy){
        $target=if((Get-SBFileHash $copy.FullName) -eq $contextHash){'context.md'}else{'memory.md'}
        Copy-Item -LiteralPath $copy.FullName -Destination (Join-Path $dossier $target) -Force
    }
    Assert-Compact ((Get-SBFileHash (Join-Path $dossier 'context.md')) -eq $contextHash -and (Get-SBFileHash (Join-Path $dossier 'memory.md')) -eq $memoryHash) 'the archived originals restore the exact files'
    'SUCCESS COMPACTAI: '+$script:compactChecks+' checks; fixture kept:'+$fixture
}finally{$env:SB_FAKE_MODE=$savedMode}
