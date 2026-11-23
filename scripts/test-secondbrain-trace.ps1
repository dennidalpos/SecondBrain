#requires -Version 7.5
# End-of-turn trace, Stop hook and compaction advice: fixtures under .runtime/tests, no writes to the real .runtime.
$ErrorActionPreference='Stop'
foreach($module in @('Core','Host','Trace','Knowledge')){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$module+'.psm1')) -Force}
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:checks=0
function Assert-Trace($Condition,[string]$Message){if(!$Condition){throw ('FAIL TRACE: '+$Message)};$script:checks++;'PASS TRACE: '+$Message}
function Reject-Trace([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Trace $rejected $Message}
$root=Join-Path (Get-SBTestRoot) ('secondbrain-trace-'+[guid]::NewGuid().ToString('N'))
try {
    $brain=Join-Path $root 'brain';$checkout=Join-Path $root 'work/repo-a';$other=Join-Path $root 'work/altro'
    foreach($dir in @($brain,$checkout,(Join-Path $checkout 'src'),$other)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
    $hostDir=Get-SBStateRoot $brain (Get-SBHostId);[IO.Directory]::CreateDirectory($hostDir)|Out-Null
    [IO.File]::WriteAllText((Join-Path $hostDir 'workstation.json'),(ConvertTo-SBJson @{schemaVersion=1;bindings=@(@{identity='github.com/acme/repo-a';path=$checkout})}))

    # Event: metadata only, repository resolved from path, no prompt text.
    $stdin=ConvertTo-Json -Compress -InputObject @{persistence='allowed';policyEvidence='synthetic fixture';session_id='sess-1';cwd=(Join-Path $checkout 'src');prompt='SEGRETO-DEL-PROMPT';transcript_path='C:/x/y.jsonl'}
    $file=Add-SBTraceEvent $brain 'stop' $stdin
    $line=@([IO.File]::ReadAllLines($file))[0];$entry=$line|ConvertFrom-Json -AsHashtable
    Assert-Trace ($file.StartsWith((Join-Path $brain '.runtime/trace'),[StringComparison]::OrdinalIgnoreCase) -and $file.EndsWith('.jsonl') -and $entry.repository -ceq 'github.com/acme/repo-a' -and $entry.sessionId -eq 'sess-1' -and $entry.event -eq 'stop') 'event queued in .runtime/trace with a resolved repository'
    Assert-Trace (!$line.Contains('SEGRETO-DEL-PROMPT') -and !$line.Contains('transcript') -and !$line.Contains($checkout)) 'the line contains no prompt, transcript or paths'
    [void](Add-SBTraceEvent $brain 'stop' (ConvertTo-Json -Compress -InputObject @{persistence='allowed';policyEvidence='fixture';session_id='sess-1';cwd=$other}))
    [void](Add-SBTraceEvent $brain 'stop' (ConvertTo-Json -Compress -InputObject @{persistence='allowed';policyEvidence='fixture';cwd=$other}))
    [void](Add-SBTraceEvent $brain 'stop' (ConvertTo-Json -Compress -InputObject @{persistence='allowed';policyEvidence='fixture';session_id='../../x';cwd=$checkout}))
    [void](Add-SBTraceEvent $brain 'stop' 'non-e-json{')
    [void](Add-SBTraceEvent $brain 'stop' '{"persistence":"disabled"}')
    $rows=@([IO.File]::ReadAllLines($file)|ForEach-Object {$_|ConvertFrom-Json -AsHashtable})
    Assert-Trace ($rows.Count -eq 4 -and $rows[1].repository -eq '' -and $rows[2].sessionId -eq '' -and $rows[3].sessionId -eq '' -and $rows[3].repository -ceq 'github.com/acme/repo-a') 'checkout and sessions validated; non-JSON input and forbidden persistence do not write'

    # Count turns by repository and time interval.
    $future=[DateTimeOffset]::Now.AddMinutes(5)
    Assert-Trace ((Get-SBTraceTurns $brain 'github.com/acme/repo-a') -eq 2 -and (Get-SBTraceTurns $brain 'github.com/acme/altro') -eq 0 -and (Get-SBTraceTurns $brain 'github.com/acme/repo-a' $future) -eq 0) 'turns counted per repository and after the last compaction'
    # Controlled clock (#528): a day/month-ambiguous timestamp (12 November) is counted against its own date under it-IT, not 11 December.
    $ambiguous=Join-Path (Split-Path $file) 'ambiguo.jsonl'
    [IO.File]::WriteAllText($ambiguous,(ConvertTo-Json -Compress -InputObject @{schemaVersion=1;ts='2026-11-12T00:35:12.0000000+01:00';ide='claude-code';sessionId='s';event='stop';repository='github.com/acme/ambiguo';cwdHash='0'})+"`n")
    $culture=[Globalization.CultureInfo]::CurrentCulture
    try{
        [Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('it-IT')
        $beforeTurn=Get-SBTraceTurns $brain 'github.com/acme/ambiguo' ([DateTimeOffset]::Parse('2026-11-12T00:30:00+01:00',[Globalization.CultureInfo]::InvariantCulture))
        $afterTurn=Get-SBTraceTurns $brain 'github.com/acme/ambiguo' ([DateTimeOffset]::Parse('2026-11-12T00:40:00+01:00',[Globalization.CultureInfo]::InvariantCulture))
    }finally{[Globalization.CultureInfo]::CurrentCulture=$culture}
    Assert-Trace ($beforeTurn -eq 1 -and $afterTurn -eq 0) 'timestamp with ambiguous day and month counted at its date even with the it-IT culture'
    Remove-Item -LiteralPath $ambiguous -Force
    $junk=Join-Path (Split-Path $file) 'illeggibile.jsonl';[IO.File]::WriteAllText($junk,"github.com/acme/repo-a rotto`n{non json`n")
    Assert-Trace ((Get-SBTraceTurns $brain 'github.com/acme/repo-a') -eq 2) 'righe illeggibili ignorate nel conteggio'

    # Compaction advice: hard beyond the limit, soft near it or after many turns, none otherwise.
    $dossier=Join-Path $root 'dossier';[IO.Directory]::CreateDirectory((Join-Path $dossier 'history/compaction'))|Out-Null
    $startup={param($chars) @{repository='github.com/acme/repo-a';characters=$chars;budget=20000}}
    Assert-Trace ((Get-SBCompactionAdvice (& $startup 20001) $brain $dossier).level -eq 'hard') 'over the cap: hard warning'
    Assert-Trace ((Get-SBCompactionAdvice (& $startup 16000) $brain $dossier).level -eq 'soft') 'all 80% del tetto: avviso soft'
    Assert-Trace ((Get-SBCompactionAdvice (& $startup 15999) $brain $dossier).level -eq 'none') 'under 80% with few turns: no warning'
    # AGENTS.md and the largest global directive count toward the soft alert; the hard level stays tied to the package alone.
    $withDirectives={param($chars,$total) @{repository='github.com/acme/repo-a';characters=$chars;budget=20000;directives=@{agents=($total-1000);globalLargest=1000;total=$total}}}
    Assert-Trace ((Get-SBCompactionAdvice (& $withDirectives 12000 4000) $brain $dossier).level -eq 'soft') 'package 12000 + directives 4000 = 80% of the cap: soft warning'
    Assert-Trace ((Get-SBCompactionAdvice (& $withDirectives 12000 3999) $brain $dossier).level -eq 'none') 'package 12000 + directives 3999 = under 80%: no warning'
    $directiveAdvice=Get-SBCompactionAdvice (& $withDirectives 12000 4000) $brain $dossier
    Assert-Trace ($directiveAdvice.totalCharacters -eq 16000 -and $directiveAdvice.directiveCharacters -eq 4000 -and $directiveAdvice.characters -eq 12000) 'il consiglio riporta pacchetto, direttive e totale'
    Assert-Trace ((Get-SBContextBudgetAlert 12000 @{total=4000} 20000).level -eq 'soft' -and $null -eq (Get-SBContextBudgetAlert 12000 @{total=3999} 20000) -and (Get-SBContextBudgetAlert 20001 @{total=0} 20000).level -eq 'hard' -and $null -eq (Get-SBContextBudgetAlert 25000 @{total=0} 0)) 'startup warning: soft at 80% of the total, hard only over the package cap, nothing without a cap'
    $directiveFiles=Join-Path $root 'directive-checkout';[IO.Directory]::CreateDirectory($directiveFiles)|Out-Null
    [IO.File]::WriteAllText((Join-Path $directiveFiles 'AGENTS.md'),('x'*1234))
    $counted=Get-SBDirectiveCharacters $directiveFiles
    Assert-Trace ($counted.agents -eq 1234 -and $counted.total -eq (1234+$counted.globalLargest) -and (Get-SBDirectiveCharacters '').agents -eq 0) 'the directives count the checkout AGENTS.md and the largest global directive'
    $heavy=Join-Path (Split-Path $file) 'altro-giorno.jsonl'
    [IO.File]::WriteAllLines($heavy,@(1..60|ForEach-Object {ConvertTo-Json -Compress -InputObject @{schemaVersion=1;ts=[DateTimeOffset]::Now.ToString('o');ide='claude-code';sessionId='s';event='stop';repository='github.com/acme/repo-a';cwdHash='0'}}))
    $many=Get-SBCompactionAdvice (& $startup 12000) $brain $dossier
    Assert-Trace ($many.level -eq 'soft' -and $many.turnsSinceCompaction -ge 60 -and (Get-SBCompactionAdvice (& $startup 9000) $brain $dossier).level -eq 'none') 'many turns with context at 60%: soft warning; under 60% none'
    $manifest=Join-Path $dossier 'history/compaction/aaaa.json';[IO.File]::WriteAllText($manifest,'{}');(Get-Item $manifest).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(10)
    $after=Get-SBCompactionAdvice (& $startup 12000) $brain $dossier
    Assert-Trace ($after.level -eq 'none' -and $after.turnsSinceCompaction -eq 0 -and $after.lastCompactionUtc) 'after a compaction the turns restart from zero'
    Remove-Item -LiteralPath $junk,$heavy -Force

    # Stop hook in settings.json: preview, idempotent install, other entries intact, removal, invalid JSON rejected.
    $settings=Join-Path $root 'claude/settings.json';[IO.Directory]::CreateDirectory((Split-Path $settings))|Out-Null
    $original=ConvertTo-SBJson @{theme='dark';hooks=@{Stop=@(@{hooks=@(@{type='command';command='echo altrui'})});PreToolUse=@(@{matcher='Bash';hooks=@(@{type='command';command='echo pre'})})}}
    [IO.File]::WriteAllText($settings,$original)
    $backups=Join-Path $root 'backups'
    $preview=Set-SBTraceHook $brain $backups -SettingsPath $settings
    Assert-Trace ($preview.preview -and !$preview.applied -and $preview.changed -and (Read-SBText $settings) -ceq $original) 'anteprima: nessuna scrittura su settings.json'
    $applied=Set-SBTraceHook $brain $backups -Apply -SettingsPath $settings
    $data=(Read-SBText $settings)|ConvertFrom-Json -AsHashtable
    $stopCommands=@($data.hooks.Stop|ForEach-Object {$_.hooks}|ForEach-Object command)
    Assert-Trace ($applied.applied -and $stopCommands -contains 'echo altrui' -and $stopCommands -contains (Get-SBTraceHookCommand $brain) -and $data.theme -eq 'dark' -and $data.hooks.PreToolUse.Count -eq 1) 'installazione: voce aggiunta, voci altrui e altre chiavi intatte'
    Assert-Trace ((Get-SBTraceHookCommand $brain) -notmatch '\\' -and (Get-SBTraceHookCommand $brain) -match 'trace\.ps1" -Event stop$' -and (Get-SBTraceHookState $brain $settings).installed) 'command with a forward-slash path and state installed'
    $hashBefore=Get-SBFileHash $settings
    $again=Set-SBTraceHook $brain $backups -Apply -SettingsPath $settings
    Assert-Trace (!$again.applied -and !$again.changed -and (Get-SBFileHash $settings) -eq $hashBefore) 'seconda installazione idempotente'
    Assert-Trace (@(Get-ChildItem -LiteralPath $backups -File -Filter '*.bin' -ErrorAction SilentlyContinue).Count -ge 1) 'installazione: backup del settings.json precedente'
    $removed=Set-SBTraceHook $brain $backups -Remove -Apply -SettingsPath $settings
    $after=(Read-SBText $settings)|ConvertFrom-Json -AsHashtable
    Assert-Trace ($removed.applied -and @($after.hooks.Stop|ForEach-Object {$_.hooks}|ForEach-Object command) -notcontains (Get-SBTraceHookCommand $brain) -and @($after.hooks.Stop|ForEach-Object {$_.hooks}|ForEach-Object command) -contains 'echo altrui' -and !(Get-SBTraceHookState $brain $settings).installed) 'rimozione: solo la voce SecondBrain, le altre restano'
    [IO.File]::WriteAllText($settings,'{non json');$invalidHash=Get-SBFileHash $settings
    Reject-Trace {Set-SBTraceHook $brain $backups -Apply -SettingsPath $settings} 'invalid settings.json: no change'
    Assert-Trace ((Get-SBFileHash $settings) -eq $invalidHash) 'invalid settings.json left intact'
    $missing=Join-Path $root 'claude/nuovo/settings.json'
    Assert-Trace ((Set-SBTraceHook $brain $backups -Apply -SettingsPath $missing).applied -and (Get-SBTraceHookState $brain $missing).installed) 'missing settings.json: created with the single entry'

    # CLI: read-only preview and status; event always exits 0 (including invalid stdin).
    $fixtureScripts=Join-Path $brain 'scripts';[IO.Directory]::CreateDirectory($fixtureScripts)|Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -File|Copy-Item -Destination $fixtureScripts
    $cli=Join-Path $fixtureScripts 'trace.ps1';$cliSettings=Join-Path $root 'claude/cli.json'
    $status=(& pwsh -NoProfile -File $cli -HookStatus -SettingsPath $cliSettings)|ConvertFrom-Json -AsHashtable
    Assert-Trace ($LASTEXITCODE -eq 0 -and !$status.installed -and !(Test-Path -LiteralPath $cliSettings)) 'CLI -HookStatus: sola lettura'
    $cliPreview=(& pwsh -NoProfile -File $cli -InstallHook -SettingsPath $cliSettings)|ConvertFrom-Json -AsHashtable
    Assert-Trace ($LASTEXITCODE -eq 0 -and $cliPreview.preview -and !$cliPreview.applied -and !(Test-Path -LiteralPath $cliSettings)) 'CLI -InstallHook without -Apply: preview only'
    'non-json{'|& pwsh -NoProfile -File $cli -Event stop -Ide test-fixture
    Assert-Trace ($LASTEXITCODE -eq 0) 'CLI -Event stop exits with 0 even with invalid input'
    . (Join-Path $PSScriptRoot 'test-trace-denied.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-memory-cycle.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-activity.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-subagents.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-subagents-cli.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-ide-observation.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-knowledge-index.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-customer.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-offboard.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-resync.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-uninstall.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-retention.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-readiness.ps1')
    & (Join-Path $PSScriptRoot 'test-orchestrator-readiness.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-workspace.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-gitupdate.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-skills.ps1')
    & (Join-Path $PSScriptRoot 'test-secondbrain-nextsteps.ps1')
    'SUCCESS TRACE: '+$script:checks+' verifiche; runtime='+$PSVersionTable.PSVersion
} finally {
    $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath((Get-SBTestRoot)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture trace fuori dal perimetro di prova'}
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $full)){
        $entries=@(Get-ChildItem -LiteralPath $full -Force -Recurse)
        foreach($entry in $entries){if(!$entry.FullName.StartsWith($full+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture trace non confinata'}}
        foreach($entry in $entries|Where-Object {!$_.PSIsContainer}){[IO.File]::SetAttributes($entry.FullName,[IO.FileAttributes]::Normal);[IO.File]::Delete($entry.FullName)}
        foreach($entry in $entries|Where-Object PSIsContainer|Sort-Object {$_.FullName.Length} -Descending){[IO.Directory]::Delete($entry.FullName)}
        [IO.Directory]::Delete($full)
    }
}
