#requires -Version 7.5
<#
.SYNOPSIS
Runs the autonomous tracker tasks of one checkout one at a time, each in a fresh `claude -p` process, then commits locally.
.DESCRIPTION
Independent of the SecondBrain runner: it only reads tracker.json and writes the dossier through SecondBrain's knowledge.ps1.
Default is a preview (selection and prompts, nothing runs). -Run executes.
Per task: require a clean tree, mark in_progress, run claude -p (prompt on stdin, timeout), read the outcome,
reopen a done task without evidence, park a todo task that produced nothing as user_required, commit the changed paths locally (never push).
A quota limit waits for the reset (up to -MaxWaitHours) and retries the same task; three consecutive failures stop the run.
State: status.json and events.jsonl in -WorkDir; create a stop file named stop.flag there to end the run before the next task.
With -Run the script copies itself into the work folder and runs the copy (-Pinned), so tasks that edit it do not change the run in progress.
Works in any repository managed by SecondBrain: the checkout defaults to the Git root of the current directory, SecondBrain to $env:SECONDBRAIN_HOME (or the folder above this script),
the dossier is found by the Git identity (origin) in 01-projects\*
epository.json, and the work folder is created with work.ps1 when -WorkDir is omitted.
SecondBrain's own scripts are not pinned: a task that edits them can change the run.
#>
[CmdletBinding()]
param(
    [string]$Checkout,
    [string]$WorkDir,
    [string]$SecondBrain,
    [string]$TrackerPath,
    [string]$Model = 'sonnet',
    [string]$Effort = 'medium',
    [string]$PermissionMode = 'acceptEdits',
    [string[]]$AllowedTools = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'PowerShell', 'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)', 'Bash(dotnet:*)', 'Bash(pwsh:*)', 'Bash(node:*)', 'Bash(python:*)', 'mcp__secondbrain'),
    [string[]]$DisallowedTools = @('Bash(git commit:*)', 'Bash(git push:*)', 'Bash(git tag:*)', 'Bash(git reset:*)', 'Bash(git clean:*)', 'Bash(git rebase:*)', 'Bash(rm:*)', 'Bash(Remove-Item:*)'),
    [int]$TimeoutMinutes = 45,
    [int]$MaxTasks = 0,
    [double]$MaxWaitHours = 6,
    [string]$ExcludePattern = 'computer-use|a schermo|a video|screen proof|installer firmato|Windows isolato',
    [string[]]$ExcludeIds = @(),
    [string]$ClaudePath,
    [switch]$IncludeExcluded,
    [switch]$Run,
    [switch]$Pinned
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Checkout) { $Checkout = (& git rev-parse --show-toplevel 2>$null) }
if (-not $Checkout) { throw 'Not inside a Git checkout; pass -Checkout.' }
$Checkout = (Resolve-Path -LiteralPath $Checkout).Path
if (-not $SecondBrain) {
    $candidates = @($env:SECONDBRAIN_HOME, (Split-Path -Parent $PSScriptRoot)) | Where-Object { $_ }
    $SecondBrain = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'scripts\knowledge.ps1') } | Select-Object -First 1
}
if (-not $SecondBrain) { throw 'SecondBrain not found; set SECONDBRAIN_HOME or pass -SecondBrain.' }
$origin = (& git -C $Checkout remote get-url origin 2>$null)
$identity = if ($origin -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') { ('github.com/{0}/{1}' -f $Matches[1], $Matches[2]).ToLowerInvariant() } else { $null }
if (-not $WorkDir) {
    if (-not $identity) { throw 'No GitHub origin to identify the repository; pass -WorkDir.' }
    Push-Location $Checkout
    try { $init = & pwsh -NoProfile -File (Join-Path $SecondBrain 'scripts\work.ps1') -Repository $identity -Init -Category report -Slug task-run | Out-String | ConvertFrom-Json }
    finally { Pop-Location }
    $WorkDir = $init.root
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if ($Run -and -not $Pinned) {
    $copy = Join-Path $WorkDir ('orchestrate-tasks.pinned-{0:yyyyMMddHHmmss}.ps1' -f (Get-Date))
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy
    $forward = @{ Checkout = $Checkout; WorkDir = $WorkDir; SecondBrain = $SecondBrain; Model = $Model; Effort = $Effort; PermissionMode = $PermissionMode
        AllowedTools = $AllowedTools; DisallowedTools = $DisallowedTools; TimeoutMinutes = $TimeoutMinutes; MaxTasks = $MaxTasks; MaxWaitHours = $MaxWaitHours
        ExcludePattern = $ExcludePattern; ExcludeIds = $ExcludeIds; Run = $true; Pinned = $true }
    if ($TrackerPath) { $forward.TrackerPath = $TrackerPath }
    if ($ClaudePath) { $forward.ClaudePath = $ClaudePath }
    if ($IncludeExcluded) { $forward.IncludeExcluded = $true }
    & $copy @forward
    return
}
$eventsFile = Join-Path $WorkDir 'events.jsonl'
$statusFile = Join-Path $WorkDir 'status.json'
$stopFile = Join-Path $WorkDir 'stop.flag'
$state = [ordered]@{ phase = 'starting'; pid = $PID; startedAt = (Get-Date).ToString('o'); model = $Model; effort = $Effort; current = $null; done = @(); failed = @(); parked = @(); skipped = @(); waitingUntil = $null; updatedAt = $null }

function Write-State([string]$Phase) {
    if ($Phase) { $state.phase = $Phase }
    $state.updatedAt = (Get-Date).ToString('o')
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8
}
function Write-Event([string]$Kind, [string]$Message, $Data = $null) {
    $record = [ordered]@{ time = (Get-Date).ToString('o'); event = $Kind; message = $Message }
    if ($null -ne $Data) { $record.data = $Data }
    ($record | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $eventsFile -Encoding utf8
    [Console]::Error.WriteLine("[$Kind] $Message")
}
function Test-Stop { Test-Path -LiteralPath $stopFile }

function Invoke-Git([string[]]$GitArgs) {
    $output = & git -C $Checkout @GitArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($output) -join "`n") }
}
function Invoke-Knowledge([string[]]$KArgs) {
    Push-Location $Checkout
    try { $text = & pwsh -NoProfile -File (Join-Path $SecondBrain 'scripts\knowledge.ps1') @KArgs 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text } }
    finally { Pop-Location }
}

# --- tracker (read only) ---
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30 }
function Get-Property($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    $Default
}
if (-not $TrackerPath) {
    $match = Get-ChildItem -Path (Join-Path $SecondBrain '01-projects') -Filter repository.json -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).identity -eq $identity } | Select-Object -First 1
    if (-not $match) { throw "No dossier with identity '$identity' in $SecondBrain-projects." }
    $TrackerPath = Join-Path $match.DirectoryName 'tracker.json'
}
$dossier = Split-Path -Parent $TrackerPath
$archivePath = Join-Path $dossier 'history\tracker-archive.json'

function Get-Tasks { @((Read-Json $TrackerPath).tasks) }
function Get-Task([string]$Id) { Get-Tasks | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
function Test-DependencyDone([string]$Id, $Tasks, $Archive) {
    $hit = $Tasks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $hit -and $Archive) { $hit = $Archive | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
    [bool]($hit -and $hit.status -eq 'done')
}
$script:attempts = @{}
function Get-Queue {
    $tasks = Get-Tasks
    $archive = if (Test-Path -LiteralPath $archivePath) { @((Read-Json $archivePath).tasks) } else { @() }
    $queue = foreach ($task in $tasks) {
        if ($task.execution -ne 'autonomous' -or $task.status -notin 'todo', 'in_progress') { continue }
        if ($task.id -in $ExcludeIds -or $task.id -in $state.failed -or $task.id -in $state.done -or $task.id -in $state.parked -or ($script:attempts[$task.id] -ge 2)) { continue }
        $ext = Get-Property $task 'extensions'
        $stream = [string](Get-Property $ext 'stream' '')
        if ($stream -match 'final-qualification|on-request|product-coordination') { continue }
        $unmet = @(@(Get-Property $task 'dependencies' @()) | Where-Object { -not (Test-DependencyDone $_.id $tasks $archive) })
        if ($unmet.Count) { continue }
        $haystack = "$($task.title) $(Get-Property $task 'blocker' '') $(Get-Property $ext 'awaiting' '')"
        if (-not $IncludeExcluded -and $ExcludePattern -and $haystack -match $ExcludePattern) {
            if ($task.id -notin $state.skipped) { $state.skipped += $task.id; Write-Event 'skip' "#$($task.seq) matches the screen/interactive filter" }
            continue
        }
        $task
    }
    @($queue | Sort-Object { [string]$_.priority }, { [int]$_.seq })
}

function New-Prompt($task) {
    $acceptance = (@($task.acceptance) | ForEach-Object { "- $_" }) -join "`n"
    $deps = (@(Get-Property $task 'dependencies' @()) | ForEach-Object { $_.id }) -join ', '
    $ext = Get-Property $task 'extensions'
    @"
You are executing ONE tracker task in a fresh session for the repository at $Checkout. Do only this task.

Task #$($task.seq) ($($task.id)) - $($task.title)
Priority: $($task.priority). Dependencies (already done): $(if ($deps) { $deps } else { 'none' })
State reason: $(Get-Property $ext 'stateReason' '-')
Description:
$(Get-Property $task 'description' '-')

Acceptance criteria:
$acceptance

Procedure:
1. Read AGENTS.md and load the startup context (MCP get_startup_context, or knowledge.ps1 -Startup run from the checkout). Follow the repository directives.
2. Do the work. Run the project checks that are relevant to what you changed, and no others.
3. Record the outcome in the dossier ONLY through SecondBrain (knowledge.ps1 run from the checkout, or the SecondBrain MCP write tools), never by editing tracker.json or other dossier files by hand:
   - evidence for each satisfied criterion: knowledge.ps1 -UpdateTaskId $($task.id) -Evidence "<reference>|<outcome>"
   - -Status done only when every criterion is really met; otherwise leave the status, and say what is missing with -StateReason.
   - if the task needs the user (a decision, an action only they can do), set -Execution user_required with -StateReason saying what.
   - add a memory line only for a new durable decision.
4. Close with secondbrain.ps1 -Sync and -Check from the SecondBrain scripts folder.
Forbidden: git commit, push, tag, reset, clean, rebase, deleting files or branches, publishing anything. The orchestrator commits your changes after you finish; leave them in the working tree.
Finish with at most 10 lines: outcome, evidence references, what is left, any blocker.
"@
}

function Resolve-Claude {
    if ($ClaudePath) { return $ClaudePath }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'claude CLI not found; pass -ClaudePath.' }
    $cmd.Source
}

function Read-Outcome([string]$OutFile) {
    $o = [ordered]@{ result = $null; isError = $false; quota = $false; resetAt = $null; text = '' }
    if (-not (Test-Path -LiteralPath $OutFile)) { return [pscustomobject]$o }
    foreach ($line in Get-Content -LiteralPath $OutFile -Encoding utf8) {
        if ($line -notmatch '^\s*\{') { continue }
        try { $j = $line | ConvertFrom-Json -Depth 20 } catch { continue }
        $type = Get-Property $j 'type'
        if ($type -eq 'rate_limit_event') {
            $info = Get-Property $j 'rate_limit_info'
            if ($info -and (Get-Property $info 'status') -eq 'rejected') {
                $o.quota = $true
                $reset = Get-Property $info 'resetsAt'
                if ($reset) { $o.resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$reset) }
            }
        }
        elseif ($type -eq 'result') {
            $o.result = $j
            $o.isError = [bool](Get-Property $j 'is_error' $false)
            $o.text = [string](Get-Property $j 'result' '')
        }
    }
    if ($o.isError -and $o.text -match "(?i)hit your limit|reached your|out of usage|limit reached") {
        $o.quota = $true
        if ($o.text -match 'limit reached\|(\d{9,11})') { $o.resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]) }
    }
    [pscustomobject]$o
}

function Wait-ForReset($OutcomeResetAt) {
    $now = [DateTimeOffset]::Now
    $until = if ($OutcomeResetAt -and $OutcomeResetAt -gt $now) { $OutcomeResetAt.AddSeconds(60) } else { $now.AddMinutes(30) }
    if (($until - $now).TotalHours -gt $script:waitBudgetHours) { return $false }
    $script:waitBudgetHours -= ($until - $now).TotalHours
    $state.waitingUntil = $until.ToString('o'); Write-State 'waiting-quota'
    Write-Event 'quota' "Waiting for the quota reset until $($until.ToString('o'))"
    while ([DateTimeOffset]::Now -lt $until) {
        if (Test-Stop) { return $false }
        Start-Sleep -Seconds 30
    }
    $state.waitingUntil = $null
    $true
}

function Invoke-ClaudeTask($task) {
    $stamp = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $task.seq
    $promptFile = Join-Path $WorkDir "prompt-$stamp.txt"
    $outFile = Join-Path $WorkDir "out-$stamp.jsonl"
    $errFile = Join-Path $WorkDir "err-$stamp.txt"
    New-Prompt $task | Set-Content -LiteralPath $promptFile -Encoding utf8
    $arguments = @('-p', '--model', $Model, '--effort', $Effort, '--permission-mode', $PermissionMode, '--output-format', 'stream-json', '--verbose', '--allowedTools') + $AllowedTools + @('--disallowedTools') + $DisallowedTools
    $proc = Start-Process -FilePath (Resolve-Claude) -ArgumentList $arguments -WorkingDirectory $Checkout -RedirectStandardInput $promptFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
    $timedOut = -not $proc.WaitForExit($TimeoutMinutes * 60000)
    if ($timedOut) { try { & taskkill /PID $proc.Id /T /F | Out-Null } catch { [void]$_ } }
    $outcome = Read-Outcome $outFile
    [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $proc.ExitCode }); TimedOut = $timedOut; Outcome = $outcome; OutFile = $outFile }
}

function Get-ChangedPaths {
    $status = Invoke-Git @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($status.Code -ne 0) { throw "git status failed: $($status.Text)" }
    @($status.Text -split "`0" | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) } | Where-Object { $_ -notmatch '^\.claude/agents/' })
}

# --- main ---
$queue = @(Get-Queue)
Write-Event 'selection' "$($queue.Count) task(s) selected" @($queue | ForEach-Object { "#$($_.seq) $($_.title)" })
if (-not $Run) {
    foreach ($task in $queue) { "--- #$($task.seq) $($task.id)"; New-Prompt $task }
    Write-State 'preview'
    return
}
$script:waitBudgetHours = $MaxWaitHours
$consecutiveFailures = 0
$executed = 0
Write-State 'running'
while ($true) {
    if (Test-Stop) { Write-Event 'stop' 'stop.flag found'; break }
    if ($MaxTasks -gt 0 -and $executed -ge $MaxTasks) { Write-Event 'stop' 'MaxTasks reached'; break }
    if ($consecutiveFailures -ge 3) { Write-Event 'stop' 'Three consecutive failures'; break }
    $queue = @(Get-Queue)
    if ($queue.Count -eq 0) { Write-Event 'stop' 'No eligible task left'; break }
    $task = $queue[0]
    $clean = Invoke-Git @('status', '--porcelain', '--untracked-files=all')
    $dirty = @($clean.Text -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\S+\s+"?\.claude/agents/' })
    if ($dirty.Count) { Write-Event 'stop' 'Working tree not clean before the task; nothing is started'; $state.failed += "dirty-before-#$($task.seq)"; break }
    $state.current = "#$($task.seq) $($task.id)"; Write-State 'running'
    Write-Event 'start' "#$($task.seq) $($task.title)"
    [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Status', 'in_progress', '-StateReason', 'Started by orchestrate-tasks.ps1'))
    $attempt = Invoke-ClaudeTask $task
    if ($attempt.Outcome.quota) {
        Write-Event 'quota' "Quota limit during #$($task.seq)"
        if (Wait-ForReset $attempt.Outcome.resetAt) { continue }
        Write-Event 'stop' 'Quota wait exceeded the budget or was stopped'; break
    }
    $executed++
    $script:attempts[$task.id] = 1 + [int]$script:attempts[$task.id]
    $after = Get-Task $task.id
    $ok = (-not $attempt.TimedOut) -and $attempt.ExitCode -eq 0 -and (-not $attempt.Outcome.isError)
    if (-not $ok) {
        $consecutiveFailures++; $state.failed += $task.id
        Write-Event 'failed' "#$($task.seq) exit $($attempt.ExitCode) timeout=$($attempt.TimedOut): $($attempt.Outcome.text)"
        [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Status', 'todo', '-StateReason', "orchestrate-tasks.ps1: session failed (exit $($attempt.ExitCode), timeout $($attempt.TimedOut)); retry or inspect $($attempt.OutFile)"))
    }
    else {
        $consecutiveFailures = 0
        $evidenceCount = @(Get-Property $after 'evidence' @()).Count
        if ($after.status -eq 'done' -and $evidenceCount -eq 0) {
            [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Status', 'in_progress', '-StateReason', 'Reopened: closed as done without evidence'))
            Write-Event 'reopened' "#$($task.seq) closed without evidence"
        }
        elseif ($after.status -in 'todo', 'in_progress' -and $after.execution -eq 'autonomous') {
            [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Execution', 'user_required', '-Status', 'todo', '-StateReason', 'Parked: the session ended without closing the task or naming a blocker'))
            $state.parked += $task.id
            Write-Event 'parked' "#$($task.seq) parked as user_required"
        }
        elseif ($after.status -eq 'done') { $state.done += $task.id }
        else {
            if ($after.status -eq 'in_progress') { [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Status', 'todo')) }
            $state.parked += $task.id
            Write-Event 'parked' "#$($task.seq) left for the user (status $($after.status), execution $($after.execution))"
        }
    }
    # local commit of the changed paths, never a push
    $paths = @(Get-ChangedPaths)
    if ($paths.Count) {
        $forbidden = @($paths | Where-Object { $_ -match '(^|/)\.claude/|\.pfx$|\.snk$|(^|/)secrets?\.|\.env$' })
        if ($forbidden.Count) { Write-Event 'blocked' "#$($task.seq) touched forbidden paths, nothing committed: $($forbidden -join ', ')"; $state.failed += "forbidden-#$($task.seq)"; break }
        [void](Invoke-Git (@('add', '--') + $paths))
        $title = ($task.title -replace '^#\d+\s*\W+\s*', '')
        $commit = Invoke-Git @('commit', '-m', "$title (#$($task.seq))", '-m', 'Executed by orchestrate-tasks.ps1 (claude -p).')
        if ($commit.Code -ne 0) { Write-Event 'blocked' "commit failed: $($commit.Text)"; break }
        Write-Event 'commit' "#$($task.seq) committed locally"
    }
    else { Write-Event 'commit' "#$($task.seq) no file changes" }
    Write-State 'running'
}
$state.current = $null
Write-State 'finished'
Write-Event 'summary' "done=$(@($state.done).Count) failed=$(@($state.failed).Count) parked=$(@($state.parked).Count) skipped=$(@($state.skipped).Count)"
