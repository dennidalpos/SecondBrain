#requires -Version 7.5
# Live check of two orchestrate-tasks.ps1 paths on a synthetic repository with a fake Claude Code (#667):
#  1. -ConfirmExtendedTools with a wider -AllowedTools: status.json authorization (profile extended, confirmer), and the task sessions receive the wider list;
#  2. a self-editing task (SelfPattern) runs after the ordinary tasks, and its local commit is the rollback point.
# Only synthetic data; the real trackers are never touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
$null = Enter-SBTestGitEnvironment
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
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

$work = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../.runtime/hosts') -Recurse -Filter status.json | Where-Object { $_.FullName -match 'orchestrator-e2e-.*task-run' -and (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).checkout -eq $fx.checkout } | Sort-Object LastWriteTime | Select-Object -Last 1
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
'SUCCESS QUEUE-LIVE: extended profile + confirmer recorded, wider list passed to 3 sessions, order ' + ($order -join ' > ') + ', one local commit per task (' + (($log | Select-Object -Skip 1) -join ' | ') + '); retained ' + $root
