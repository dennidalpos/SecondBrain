#requires -Version 7.5
# #744: the orchestrate-tasks.ps1 preview skips a task whose stored readiness has a failed check (with the reason), still queues a ready task,
# and puts extensions.files and extensions.checks in the prompt. Synthetic fixture only, no agent is started.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
$null = Enter-SBTestGitEnvironment
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$root = Join-Path (Get-SBTestRoot) ('orch-ready-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$fixtureText = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-orchestrator-fixture.ps1') -Root $root 2>&1 | Out-String)
if ($LASTEXITCODE) { throw ('FAIL ORCH-READY: fixture: ' + $fixtureText) }
$fx = $fixtureText | ConvertFrom-Json -AsHashtable
function Fail([string]$m) { throw ('FAIL ORCH-READY: ' + $m) }
$tracker = Get-Content -LiteralPath $fx.tracker -Raw | ConvertFrom-Json -Depth 30
foreach ($task in $tracker.tasks) {
    if ($task.id -eq 'E2E-1') {
        $task.extensions | Add-Member -NotePropertyName readiness -NotePropertyValue ([pscustomobject]@{ ready = $false; checks = @([pscustomobject]@{ check = 'inputs'; passed = $false; missing = @('provenance') }) }) -Force
    }
    if ($task.id -eq 'E2E-2') {
        $task.extensions | Add-Member -NotePropertyName files -NotePropertyValue @('src/example.ps1') -Force
        $task.extensions | Add-Member -NotePropertyName checks -NotePropertyValue @('pwsh -File scripts/test-secondbrain.ps1 -Quick') -Force
        $task.extensions | Add-Member -NotePropertyName readiness -NotePropertyValue ([pscustomobject]@{ ready = $false; checks = @([pscustomobject]@{ check = 'scope'; passed = $false; missing = @('stream') }) }) -Force
    }
}
[IO.File]::WriteAllText($fx.tracker, ($tracker | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$env:SECONDBRAIN_HOME = $fx.brain
$run = Join-Path $fx.brain 'scripts/orchestrate-tasks.ps1'
Push-Location $fx.checkout
try { $out = (& pwsh -NoProfile -File $run -SecondBrain $fx.brain -Checkout $fx.checkout -AgentPath (Join-Path $fx.bin ($IsWindows ? 'claude.cmd' : 'claude')) 2>&1 | Out-String) }
finally { Pop-Location }
if ($out -notmatch 'E2E-2') { Fail ('the ready task E2E-2 is not in the preview: ' + $out) }
if ($out -match 'Task #\d+ \(E2E-1\)') { Fail 'the not-ready task E2E-1 was queued' }
if ($out -notmatch 'Files in scope' -or $out -notmatch 'src/example\.ps1' -or $out -notmatch 'Checks to run' -or $out -notmatch 'test-secondbrain\.ps1 -Quick') { Fail ('the prompt lacks files and checks: ' + $out) }
if ($out -notmatch 'not ready \(readiness:inputs:provenance\)|readiness:inputs:provenance') { Fail ('the skip reason is not shown: ' + $out) }
Write-Output ('SUCCESS ORCH-READY: 4 checks; retained fixture ' + $root)
