#requires -Version 7.5
# Live check of two orchestrate-tasks.ps1 paths on a synthetic repository with a fake Claude Code (#667):
#  1. -ConfirmExtendedTools with a wider -AllowedTools: status.json authorization (profile extended, confirmer), and the task sessions receive the wider list;
#  2. a self-editing task (SelfPattern) runs after the ordinary tasks, and its local commit is the rollback point.
#  3. #773: linked worktree with a fork origin alias, worker-report bookkeeping, preflight rejection, rejected start and a fatal health check (nonzero exit).
# Only synthetic data; the real trackers are never touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
$null = Enter-SBTestGitEnvironment
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$testStart = [DateTimeOffset]::Now.AddSeconds(-1)
$root = Join-Path (Get-SBTestRoot) ('queue-live-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$fixtureText = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-orchestrator-fixture.ps1') -Root $root 2>&1 | Out-String)
if ($LASTEXITCODE) { throw ('FAIL QUEUE-LIVE: fixture: ' + $fixtureText) }
$fx = $fixtureText | ConvertFrom-Json -AsHashtable
function Fail([string]$m) { throw ('FAIL QUEUE-LIVE: ' + $m) }
function Invoke-Repo { & git -c core.longpaths=true -C $fx.checkout @args 2>&1 }

# The highest-priority task (E2E-1, P1) becomes the self-editing one: it must still run last.
$tracker = Get-Content -LiteralPath $fx.tracker -Raw | ConvertFrom-Json -Depth 30
$tracker.tasks | Where-Object { $_.id -eq 'E2E-1' } | ForEach-Object { $_.title = $_.title + ' edits orchestrate-tasks.ps1' }
[IO.File]::WriteAllText($fx.tracker, ($tracker | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))

# Fake agent: records its arguments, changes one file in the checkout, closes the task with evidence.
$fake = Join-Path $fx.bin 'fake-claude.ps1'
[IO.File]::WriteAllText($fake, @'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($args -contains '--version'){'9.9.9 (Claude Code)';exit 0}
$prompt=[Console]::In.ReadToEnd()
$id=if($prompt -match 'ONLY task (\S+)|ONLY the task (\S+)|task (E2E-\d)'){($Matches[1],$Matches[2],$Matches[3]|Where-Object{$_}|Select-Object -First 1)}else{''}
$log=Join-Path (Split-Path $env:SB_LIVE_BRAIN) 'sessions.log'
Add-Content -LiteralPath $log -Value (@{id=$id;args=($args -join ' ');at=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress)
Set-Content -LiteralPath (Join-Path (Get-Location).Path ("work-$id.txt")) -Value $id
# #699: the first task changes the SecondBrain scripts (a new file), so the queue must retake its scripts snapshot afterwards.
if($id -eq 'E2E-2'){Set-Content -LiteralPath (Join-Path $env:SB_LIVE_BRAIN 'scripts/queue-refresh-probe.ps1') -Value '# probe'}
& pwsh -NoProfile -File (Join-Path $env:SB_LIVE_BRAIN 'scripts/knowledge.ps1') -CheckoutPath (Get-Location).Path -UpdateTaskId $id -Evidence "work-$id.txt|passed" -Status done|Out-Null
[Console]::Out.WriteLine((@{type='result';subtype='success';is_error=$false;result='ok'}|ConvertTo-Json -Compress))
exit 0
'@, [Text.UTF8Encoding]::new($false))

$env:SB_LIVE_BRAIN = $fx.brain
$env:SECONDBRAIN_HOME = $fx.brain
Invoke-Repo add -A | Out-Null
Invoke-Repo -c user.name=t -c user.email=t@example.com commit -q -m 'initial' | Out-Null
$wider = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'PowerShell', 'Bash(git status:*)', 'Bash(npm:*)')
$widerList = ($wider | ForEach-Object { "'$_'" }) -join ','
$agent = Join-Path $fx.bin ($IsWindows ? 'claude.cmd' : 'claude')
$run = Join-Path $fx.brain 'scripts/orchestrate-tasks.ps1'
Push-Location $fx.checkout
try {
    & git -c user.name=t -c user.email=t@example.com config user.name t
    & git config user.email t@example.com
    # Without confirmation the wider list is refused.
    $refused = $false
    try { & pwsh -NoProfile -Command ("& '{0}' -Run -SecondBrain '{1}' -Checkout '{2}' -AgentPath '{3}' -AllowedTools {4} -HealthChecks tracker -AllowNoPowerRequest" -f $run,$fx.brain,$fx.checkout,$agent,$widerList) 2>&1 | Out-Null; $refused = $LASTEXITCODE -ne 0 } catch { $refused = $true }
    if (-not $refused) { Fail 'wider -AllowedTools without -ConfirmExtendedTools was not refused' }
    $out = & pwsh -NoProfile -Command ("& '{0}' -Run -ConfirmExtendedTools -SecondBrain '{1}' -Checkout '{2}' -AgentPath '{3}' -AllowedTools {4} -HealthChecks tracker -AllowNoPowerRequest" -f $run,$fx.brain,$fx.checkout,$agent,$widerList) 2>&1 | Out-String
}
finally { Pop-Location }

$work = @((Join-Path $fx.brain '.runtime'), (Join-Path $PSScriptRoot '../.runtime/hosts')) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Filter status.json } | Where-Object { $_.FullName -match 'orchestrator-e2e-.*task-run' -and (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).checkout -eq $fx.checkout } | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $work) { Fail ('no status.json; output: ' + $out) }
$status = Get-Content -LiteralPath $work.FullName -Raw | ConvertFrom-Json -Depth 10
$auth = $status.authorization
if ($auth.profile -ne 'extended' -or -not $auth.confirmed -or -not $auth.confirmedBy) { Fail ('authorization not recorded: ' + ($auth | ConvertTo-Json -Compress)) }
if ((@($auth.allowedTools) -join ',') -ne ($wider -join ',')) { Fail 'status.json allowedTools differs from the wider list' }
$sessions = @(Get-Content -LiteralPath (Join-Path $root 'sessions.log') | ForEach-Object { $_ | ConvertFrom-Json })
if ($sessions.Count -ne 3) { Fail ("expected 3 sessions, got $($sessions.Count); output: $out") }
foreach ($s in $sessions) { if ($s.args -notmatch [regex]::Escape('--allowedTools ' + ($wider -join ' ') + ' --disallowedTools')) { Fail ("session $($s.id) did not receive the wider list: $($s.args)") } }
$order = @($sessions.id)
if ($order[-1] -ne 'E2E-1' -or ($order[0..1] -join ',') -ne 'E2E-2,E2E-3') { Fail ('order was ' + ($order -join ',') + ', expected E2E-2,E2E-3,E2E-1') }
$log = @(Invoke-Repo log --format=%s --reverse)
$last = Invoke-Repo show --name-only --format=%s HEAD
if ((@($last) -join ' ') -notmatch 'work-E2E-1\.txt') { Fail ('last commit is not the self-editing task: ' + ($last -join ' ')) }
if (@(Invoke-Repo status --porcelain).Count) { Fail 'working tree not clean after the run' }
# #699: a task that changes scripts/ retakes the pinned snapshot; the queue continues and the event records the new manifest hash.
# The work folder is named by repository and date, so a rerun on the same day appends to the same events.jsonl: only this test's events count.
$events = @(Get-Content -LiteralPath (Join-Path $work.DirectoryName 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -Depth 10 } | Where-Object { [DateTimeOffset]$_.time -ge $testStart })
$snapshots = @($events | Where-Object { $_.event -eq 'snapshot' })
if ($snapshots.Count -ne 2 -or -not $snapshots[1].data.manifestHash -or $snapshots[1].data.manifestHash -eq $snapshots[0].data.manifestHash) { Fail ('snapshot was not retaken exactly once with a new manifest hash: ' + (($snapshots | ForEach-Object { $_.message }) -join ' | ')) }
if (-not (Test-Path -LiteralPath (Join-Path $snapshots[1].data.snapshot 'scripts/queue-refresh-probe.ps1'))) { Fail 'the retaken snapshot does not hold the changed script' }
if (Test-Path -LiteralPath (Join-Path $snapshots[0].data.snapshot 'scripts/queue-refresh-probe.ps1')) { Fail 'the first snapshot was modified after it was taken' }
if (@($events | Where-Object { $_.event -eq 'scripts-changed' }).Count -lt 1) { Fail 'the script change was not reported' }
if (@($events | Where-Object { $_.event -eq 'health' -and $_.message -match 'failed' }).Count) { Fail 'a health check failed after the snapshot refresh' }
# -InstallAgent needs no dossier: a plain Git repository gets the supervisor definition for each provider once, never overwritten, English ASCII text.
$plain = Join-Path $root 'plain-repo'
[IO.Directory]::CreateDirectory($plain) | Out-Null
& git -C $plain init -q
foreach ($provider in 'claude', 'codex', 'gemini') {
    $first = (& pwsh -NoProfile -File $run -InstallAgent -Provider $provider -SecondBrain $fx.brain -Checkout $plain 2>&1 | Out-String)
    if ($LASTEXITCODE -or $first -notmatch '"state":\s*"created"') { Fail ("-InstallAgent $provider in a repository without a dossier: " + $first) }
    $file = Get-ChildItem -LiteralPath $plain -Recurse -File -Filter 'task-queue-supervisor.md' | Where-Object { $_.FullName -match [regex]::Escape($provider) } | Select-Object -First 1
    if (-not $file) { Fail "no supervisor file written for $provider" }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count) { Fail "the $provider supervisor definition is not plain ASCII English text" }
    $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
    $second = (& pwsh -NoProfile -File $run -InstallAgent -Provider $provider -SecondBrain $fx.brain -Checkout $plain 2>&1 | Out-String)
    if ($second -notmatch '"state":\s*"exists"' -or (Get-FileHash -LiteralPath $file.FullName).Hash -ne $hash) { Fail "-InstallAgent $provider overwrote or did not report the existing file: $second" }
}
# --- #773: bookkeeping scenarios (worktree binding, worker report, preflight, rejected writes, fatal health) ---
$fakeReport = @'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($args -contains '--version'){'9.9.9 (Claude Code)';exit 0}
$prompt=[Console]::In.ReadToEnd()
$id=if($prompt -match '\((E2E-\d)\)'){$Matches[1]}else{''}
Add-Content -LiteralPath $env:SB_FAKE_LOG -Value $id
Set-Content -LiteralPath (Join-Path (Get-Location).Path "work-$id.txt") -Value $id
if(Test-Path -LiteralPath (Join-Path $env:SB_STUB_DIR 'arm-fail')){Set-Content -LiteralPath (Join-Path $env:SB_STUB_DIR 'fail-tasks') -Value 'x'}
# The worker never touches the dossier: it only reports.
$report=@{taskId=$id;status='done';evidence=@(@{reference="work-$id.txt";outcome='passed'});reason=''}|ConvertTo-Json -Compress -Depth 5
[Console]::Out.WriteLine((@{type='result';subtype='success';is_error=$false;result=("Finished.`nSB-RESULT: "+$report)}|ConvertTo-Json -Compress))
exit 0
'@
$stubKnowledge = @'
$a=@($args)
if((Test-Path -LiteralPath (Join-Path $env:SB_STUB_DIR 'reject-start')) -and ($a -contains 'in_progress')){'{"state":"rejected"}';exit 3}
if((Test-Path -LiteralPath (Join-Path $env:SB_STUB_DIR 'fail-tasks')) -and ($a -contains '-Tasks')){'boom';exit 4}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'knowledge.real.ps1') @a
exit $LASTEXITCODE
'@
function New-Scenario([string]$Name) {
    $r = Join-Path $root $Name
    $t = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-orchestrator-fixture.ps1') -Root $r 2>&1 | Out-String)
    if ($LASTEXITCODE) { Fail "scenario $Name fixture: $t" }
    $f = $t | ConvertFrom-Json -AsHashtable
    $f.root = $r; $f.log = Join-Path $r 'agent-sessions.log'
    [IO.File]::WriteAllText((Join-Path $f.bin 'fake-claude.ps1'), $fakeReport, [Text.UTF8Encoding]::new($false))
    & git -c core.longpaths=true -C $f.checkout add -A 2>&1 | Out-Null
    & git -c core.longpaths=true -C $f.checkout -c user.name=t -c user.email=t@example.com commit -q -m initial 2>&1 | Out-Null
    & git -C $f.checkout config user.name t; & git -C $f.checkout config user.email t@example.com
    $f
}
function Invoke-Orch($f, [string]$Cwd, [string]$Id) {
    $script:runStart = [DateTimeOffset]::Now.AddSeconds(-1)
    $env:SECONDBRAIN_HOME = $f.brain; $env:SB_FAKE_LOG = $f.log; $env:SB_STUB_DIR = $f.root
    Push-Location $Cwd
    try {
        $o = & pwsh -NoProfile -File (Join-Path $f.brain 'scripts/orchestrate-tasks.ps1') -Run -WorkerReport -SecondBrain $f.brain -Checkout $Cwd -AgentPath (Join-Path $f.bin ($IsWindows ? 'claude.cmd' : 'claude')) -OnlyIds $Id -MaxTasks 1 -HealthChecks tracker,tasks -AllowNoPowerRequest 2>&1 | Out-String
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = $o }
    }
    finally { Pop-Location }
}
function Get-RunInfo($f, [string]$Cwd, [DateTimeOffset]$RunStart = $script:runStart) {
    $file = @((Join-Path $f.brain '.runtime'), (Join-Path $PSScriptRoot '../.runtime/hosts')) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Filter status.json -ErrorAction SilentlyContinue } | Where-Object { $_.FullName -match 'orchestrator-e2e-.*task-run' } | Where-Object { $j =Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; $j.kind -eq 'orchestrate-tasks' -and $j.checkout -eq (Resolve-Path -LiteralPath $Cwd).Path } | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $file) { return $null }
    $events = @(Get-Content -LiteralPath (Join-Path $file.DirectoryName 'events.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json -Depth 10 } | Where-Object { [DateTimeOffset]$_.time -ge $RunStart })
    [pscustomobject]@{ Status = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 10); Events = $events }
}
function Get-FixtureTask($f, [string]$Id) {
    $archive = Join-Path (Split-Path $f.tracker) 'history/tracker-archive.json'
    $all = @((Get-Content -LiteralPath $f.tracker -Raw | ConvertFrom-Json -Depth 30).tasks) + @((Get-Content -LiteralPath $archive -Raw | ConvertFrom-Json -Depth 30).tasks)
    $all | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}
function Get-AgentSessions($f) { if (Test-Path -LiteralPath $f.log) { @(Get-Content -LiteralPath $f.log) } else { @() } }

# 1. Linked worktree of a bound checkout whose origin is a fork alias: the same canonical dossier for start, evidence and health.
$w = New-Scenario 'wt'
$fork = 'github.com/fork/orchestrator-e2e'
& git -C $w.checkout remote set-url origin "https://$fork.git"
$cfg = Get-Content -LiteralPath $w.config -Raw | ConvertFrom-Json -AsHashtable
$cfg.bindings[0].remoteIdentity = $fork
[IO.File]::WriteAllText($w.config, ($cfg | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$repoFile = Join-Path $w.dossier 'repository.json'
$repoJson = Get-Content -LiteralPath $repoFile -Raw | ConvertFrom-Json -AsHashtable
$repoJson.aliases = @($fork)
[IO.File]::WriteAllText($repoFile, ($repoJson | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$tree = Join-Path $w.root 'wt-tree'
& git -C $w.checkout worktree add -q $tree -b wt-branch 2>&1 | Out-Null
$tree2 = Join-Path $w.root 'wt-tree2'
& git -C $w.checkout worktree add -q $tree2 -b wt-branch2 2>&1 | Out-Null
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
$binding = @{ identity = $w.identity; path = $w.checkout; remoteIdentity = $fork }
if ((Resolve-SBBoundIdentity $tree @($binding)) -cne $w.identity) { Fail 'a linked worktree did not inherit the binding of the checkout sharing its Git directory' }
$ambiguous = $false
try { [void](Resolve-SBBoundIdentity $tree @($binding, @{ identity = $w.identity; path = $tree2; remoteIdentity = $fork })) } catch { $ambiguous = $true }
if (-not $ambiguous) { Fail 'two bindings sharing one Git directory were not rejected as ambiguous' }
if ((Resolve-SBBoundIdentity $tree @(@{ identity = $w.identity; path = $w.checkout; remoteIdentity = 'github.com/other/changed' })) -ceq $w.identity) { Fail 'a changed origin inherited the binding' }
$clone = Join-Path $w.root 'unrelated'
[IO.Directory]::CreateDirectory($clone) | Out-Null
& git -C $clone init -q; & git -C $clone remote add origin "https://$fork.git"
if ((Resolve-SBBoundIdentity $clone @($binding)) -ceq $w.identity) { Fail 'an unrelated clone with the same origin inherited the binding' }
$run1 = Invoke-Orch $w $tree 'E2E-2'
if ($run1.Code -ne 0) { Fail ("worktree run exited $($run1.Code): " + $run1.Output) }
$info = Get-RunInfo $w $tree
if ($info.Status.result -ne 'completed' -or $info.Status.exitCode -ne 0 -or $info.Status.phase -ne 'finished') { Fail ('worktree run status: ' + ($info.Status | ConvertTo-Json -Compress -Depth 4) + ' output: ' + $run1.Output) }
$closed = Get-FixtureTask $w 'E2E-2'
if ($closed.status -ne 'done' -or -not (@($closed.evidence | ForEach-Object { ($_ | ConvertTo-Json -Compress) }) -match 'work-E2E-2\.txt')) { Fail ('worker report was not recorded by the host: ' + ($closed | ConvertTo-Json -Compress -Depth 6)) }
if (@($info.Events | Where-Object { $_.event -eq 'bookkeeping-rejected' }).Count -or -not @($info.Events | Where-Object { $_.event -eq 'health' -and $_.message -match 'passed' }).Count) { Fail 'the worktree run reported a rejection or no passing health check' }
if ((@(& git -C $tree log -1 --format=%s) -join '') -notmatch '\(#2\)') { Fail 'no local commit in the linked worktree' }

# 2. Preflight: an unbound clone resolves to the fork alias, not the canonical dossier: nothing is launched.
& git -C $clone -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init 2>&1 | Out-Null
$run2 = Invoke-Orch $w $clone 'E2E-3'
if ($run2.Code -eq 0) { Fail ('an unresolved bookkeeping target did not fail the run: ' + $run2.Output) }
if (@(Get-AgentSessions $w).Count -ne 1) { Fail 'an agent was launched despite an unresolved bookkeeping target' }

# 3. Rejected start: no agent, visible rejection, nonzero exit, accurate final status. 4. Fatal health check after a normal task.
$s = New-Scenario 'stub'
Move-Item -LiteralPath (Join-Path $s.brain 'scripts/knowledge.ps1') -Destination (Join-Path $s.brain 'scripts/knowledge.real.ps1')
[IO.File]::WriteAllText((Join-Path $s.brain 'scripts/knowledge.ps1'), $stubKnowledge, [Text.UTF8Encoding]::new($false))
Set-Content -LiteralPath (Join-Path $s.root 'reject-start') -Value 'x'
$run3 = Invoke-Orch $s $s.checkout 'E2E-2'
$info3 = Get-RunInfo $s $s.checkout
if ($run3.Code -eq 0 -or -not $info3 -or $info3.Status.result -ne 'failed' -or $info3.Status.exitCode -ne 1) { Fail ('a rejected start did not end failed with a nonzero exit: ' + $run3.Code + ' ' + ($info3.Status | ConvertTo-Json -Compress -Depth 4)) }
if (@(Get-AgentSessions $s).Count) { Fail 'an agent was launched after a rejected start' }
if (-not @($info3.Events | Where-Object { $_.event -eq 'bookkeeping-rejected' -and $_.message -match 'start' }).Count -or @($info3.Events | Where-Object { $_.event -eq 'evidence' }).Count) { Fail 'the rejected start was not visible, or was reported as applied' }
if ((Get-FixtureTask $s 'E2E-2').status -ne 'todo') { Fail 'the task changed state although the start was rejected' }
Remove-Item -LiteralPath (Join-Path $s.root 'reject-start') -Force
Set-Content -LiteralPath (Join-Path $s.root 'arm-fail') -Value 'x'
$run4 = Invoke-Orch $s $s.checkout 'E2E-2'
$info4 = Get-RunInfo $s $s.checkout
if ($run4.Code -eq 0 -or $info4.Status.result -ne 'failed' -or @($info4.Status.failed) -notcontains 'health-#2') { Fail ('a fatal health failure did not end failed with a nonzero exit: ' + $run4.Code + ' ' + ($info4.Status | ConvertTo-Json -Compress -Depth 4)) }
if ((Get-FixtureTask $s 'E2E-2').status -ne 'done') { Fail 'the host did not record the worker report before the health check failed' }

'SUCCESS QUEUE-LIVE: snapshot retaken once after a script change, extended profile + confirmer recorded, wider list passed to 3 sessions, order ' + ($order -join ' > ') + ', one local commit per task (' + (($log | Select-Object -Skip 1) -join ' | ') + '); bookkeeping scenarios (linked worktree + fork alias, worker report, preflight, rejected start, fatal health) passed; retained ' + $root
