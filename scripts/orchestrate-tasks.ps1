#requires -Version 7.5
<#
.SYNOPSIS
Runs the autonomous tracker tasks of one checkout one at a time, each in a fresh headless agent process (Claude Code, Codex or Gemini CLI), on a queue branch, with local commits only.
.DESCRIPTION
Independent of the SecondBrain runner: it reads tracker.json and writes the dossier through SecondBrain's knowledge.ps1.
Default is a preview (selection and prompts, nothing runs). Switches:
  -Run                    execute; creates a queue/<yyyyMMdd-HHmm> branch first (never master or main) unless already on a queue/* branch.
  -Status                 print the state of the latest run (phase, pid alive, current task, counters, notice, last events).
  -Stop                   create stop.flag in the latest run folder: the run ends before the next task.
  -InstallAgent           write the context-free supervisor agent definition for -Provider into the checkout; never overwrites a file.
  -Provider               claude (default), codex or gemini; the headless CLI comes from SecondBrain.AgentAdapters (-AgentPath overrides the executable).
  -ConfirmExtendedTools   required before -PermissionMode, -AllowedTools or -DisallowedTools differ from the defaults; recorded in status.json.
  -OnlyIds                restrict the selection to these task ids (comma separated).
  -HealthChecks           comma list of tracker,tasks,quick,check run after each task (default all four).
  -AllowNoPowerRequest    run even when the Windows power request (no idle sleep) is refused.
Per task: tree must be clean (except when resuming the interrupted task), mark in_progress, run the session (prompt on stdin, timeout),
read the outcome, reopen a done task without evidence, park a todo task that produced nothing as user_required, commit the changed paths
locally (never push), record run evidence in the tracker, then run the health check (tracker readable, knowledge.ps1 -Tasks, test-secondbrain.ps1 -Quick,
secondbrain.ps1 -Check). A failed health check stops the run with a notice; nothing is reverted, reset, cleaned or stashed.
Tasks that edit the orchestrator or the runner themselves are ordered last. A quota limit waits for the reset (up to -MaxWaitHours) and retries
the same task; three consecutive failures stop the run.
Resume: a run cut while running (status.json phase running, pid gone) is resumed by running -Run again: the work folder, the counters and the interrupted
task come from status.json, the dirty tree left by that task is accepted for that task only, and the new session is told to continue its partial work.
State: status.json, events.jsonl, NOTICE.txt (on stop or failure) and stop.flag in the work folder (.runtime/hosts/<host>/repos/<repo>/report/<date>-task-run, created with work.ps1).
With -Run the script copies itself into the work folder and runs the copy (-Pinned). SecondBrain's own scripts cannot be pinned (the brain root is the
parent of the scripts folder and the dossier write guard refuses junctions): their SHA-256 manifest is taken at start and a change is reported after each task.
Works in any repository managed by SecondBrain: the checkout defaults to the Git root of the current directory, SecondBrain to $env:SECONDBRAIN_HOME
(or the folder above this script), the dossier is found by the Git identity (origin) in 01-projects\*\repository.json.
#>
[CmdletBinding()]
param(
    [string]$Checkout,
    [string]$WorkDir,
    [string]$SecondBrain,
    [string]$TrackerPath,
    [ValidateSet('claude', 'codex', 'gemini')][string]$Provider = 'claude',
    [string]$Model,
    [string]$Effort = 'medium',
    [string]$PermissionMode = 'acceptEdits',
    [string[]]$AllowedTools = @('Read', 'Edit', 'Write', 'Glob', 'Grep', 'PowerShell', 'Bash(git status:*)', 'Bash(git diff:*)', 'Bash(git log:*)', 'Bash(git show:*)', 'Bash(dotnet:*)', 'Bash(pwsh:*)', 'Bash(node:*)', 'Bash(python:*)', 'mcp__secondbrain'),
    [string[]]$DisallowedTools = @('Bash(git commit:*)', 'Bash(git push:*)', 'Bash(git tag:*)', 'Bash(git reset:*)', 'Bash(git clean:*)', 'Bash(git rebase:*)', 'Bash(rm:*)', 'Bash(Remove-Item:*)'),
    [int]$TimeoutMinutes = 45,
    [int]$MaxTasks = 0,
    [double]$MaxWaitHours = 6,
    [ValidateRange(1, 100)][double]$QuotaLowPercent = 95,
    [string]$ScriptsSnapshot,
    [string]$ExcludePattern = 'computer-use|a schermo|a video|screen proof|installer firmato|Windows isolato',
    [string]$SelfPattern = 'orchestrate-tasks|run-ready-tasks|SecondBrain\.TaskRunner|SecondBrain\.AgentAdapters|SecondBrain\.RunnerStatus',
    [string[]]$ExcludeIds = @(),
    [string[]]$OnlyIds = @(),
    [string]$Branch,
    [Alias('ClaudePath')][string]$AgentPath,
    [ValidatePattern('^(tracker|tasks|quick|check)(,(tracker|tasks|quick|check))*$')][string]$HealthChecks = 'tracker,tasks,quick,check',
    [switch]$ConfirmExtendedTools,
    [switch]$AllowNoPowerRequest,
    [switch]$IncludeExcluded,
    [switch]$Run,
    [switch]$Status,
    [switch]$Stop,
    [switch]$InstallAgent,
    [switch]$Pinned,
    [switch]$ExtendedProfile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# With pwsh -File a comma list arrives as one string: split every element.
$ExcludeIds = @($ExcludeIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$OnlyIds = @($OnlyIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $SecondBrain) {
    $candidates = @($env:SECONDBRAIN_HOME, (Split-Path -Parent $PSScriptRoot)) | Where-Object { $_ }
    $SecondBrain = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'scripts\knowledge.ps1') } | Select-Object -First 1
}
# Messages and adapters come from the SecondBrain modules (a pinned copy runs from the work folder, so $PSScriptRoot is not enough).
$moduleRoot = if ($SecondBrain) { Join-Path $SecondBrain 'scripts' } else { $PSScriptRoot }
# #665: a run works from a snapshot of scripts/, config/ and VERSION taken at start (-ScriptsSnapshot), so a task that edits a script never changes the
# bookkeeping and health checks of the same run. SECONDBRAIN_BRAIN_ROOT points the snapshot at the live dossier; it is set before any module loads.
if ($ScriptsSnapshot -and (Test-Path -LiteralPath (Join-Path $ScriptsSnapshot 'scripts\SecondBrain.Core.psm1'))) {
    $env:SECONDBRAIN_BRAIN_ROOT = $SecondBrain
    $moduleRoot = Join-Path $ScriptsSnapshot 'scripts'
}
else { $ScriptsSnapshot = $null }
$scriptsDir = if ($ScriptsSnapshot) { Join-Path $ScriptsSnapshot 'scripts' } else { Join-Path $SecondBrain 'scripts' }
Import-Module (Join-Path $moduleRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $moduleRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $moduleRoot 'SecondBrain.AgentAdapters.psm1')
Import-Module (Join-Path $moduleRoot 'SecondBrain.RunnerStatus.psm1')
Import-Module (Join-Path $moduleRoot 'SecondBrain.Host.psm1')
Add-SBMessages @{
    'orchestrate.checkout.missing' = @{ en = 'Not inside a Git checkout; pass -Checkout' }
    'orchestrate.brain.missing' = @{ en = 'SecondBrain not found; set SECONDBRAIN_HOME or pass -SecondBrain' }
    'orchestrate.identity.missing' = @{ en = 'No GitHub origin to identify the repository; pass -WorkDir' }
    'orchestrate.dossier.missing' = @{ en = "No dossier with identity '{0}' in {1}" }
    'orchestrate.agent.missing' = @{ en = '{0} CLI not found; pass -AgentPath' }
    'orchestrate.git.status' = @{ en = 'git status failed: {0}' }
    'orchestrate.branch.protected' = @{ en = "Refusing to run on branch '{0}': the queue runs on a dedicated queue/* branch" }
    'orchestrate.branch.dirty' = @{ en = 'The working tree is not clean: commit or inspect it before the queue branch is created' }
    'orchestrate.branch.failed' = @{ en = 'Could not create the queue branch {0}: {1}' }
    'orchestrate.extended.unconfirmed' = @{ en = 'Wider tool access was requested (-PermissionMode, -AllowedTools or -DisallowedTools differ from the defaults). Repeat the command with -ConfirmExtendedTools to confirm it; the confirmation is recorded in status.json' }
    'orchestrate.extended.provider' = @{ en = 'Extended tool access is only supported with -Provider claude' }
    'orchestrate.alive' = @{ en = 'An orchestrator run is already active (pid {0}, work folder {1}); use -Status or -Stop' }
    'orchestrate.power.refused' = @{ en = 'The power request was not acquired ({0}): the computer could sleep during the run. Run again with -AllowNoPowerRequest to run without this protection' }
    'orchestrate.run.none' = @{ en = 'No orchestrator run found for {0}' }
    'orchestrate.agent.exists' = @{ en = 'Agent definition already exists, not overwritten: {0}' }
}
if (-not $SecondBrain) { throw (New-SBError 'orchestrate.brain.missing') }
if (-not $Checkout) { $Checkout = (& git rev-parse --show-toplevel 2>$null) }
if (-not $Checkout) { throw (New-SBError 'orchestrate.checkout.missing') }
$Checkout = (Resolve-Path -LiteralPath $Checkout).Path
$origin = (& git -C $Checkout remote get-url origin 2>$null)
$identity = if ($origin -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') { ('github.com/{0}/{1}' -f $Matches[1], $Matches[2]).ToLowerInvariant() } else { $null }

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30 }
function Get-Property($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    $Default
}
function Invoke-Git([string[]]$GitArgs) {
    $output = & git -C $Checkout @GitArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($output) -join "`n") }
}
function Get-CurrentBranch { (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim() }
function Test-ProtectedBranch([string]$Name) { $Name -in 'master', 'main', 'HEAD' -or $Name -notmatch '^queue/' }

# --- dossier ---
if (-not $TrackerPath) {
    $match = @('01-projects', '02-areas', '03-resources') | ForEach-Object { Join-Path $SecondBrain $_ } | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -Path $_ -Filter repository.json -Recurse -Depth 2 -ErrorAction SilentlyContinue } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).identity -eq $identity } | Select-Object -First 1
    if (-not $match) { throw (New-SBError 'orchestrate.dossier.missing' @($identity, (Join-Path $SecondBrain '01-projects, 02-areas, 03-resources'))) }
    $TrackerPath = Join-Path $match.DirectoryName 'tracker.json'
}
$dossier = Split-Path -Parent $TrackerPath
$archivePath = Join-Path $dossier 'history\tracker-archive.json'

function Test-ProcessAlive($ProcessId) {
    if (-not $ProcessId) { return $false }
    [bool](Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
}
function Get-RunFolders {
    # Work folders live in the workstation area (.runtime/hosts/<host>/repos/<repo>/report); runs are told apart by kind and checkout.
    $pattern = Join-Path $SecondBrain '.runtime/hosts/*/repos/*/report/*task-run*'
    @(Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Where-Object {
        $file = Join-Path $_.FullName 'status.json'
        if (-not (Test-Path -LiteralPath $file)) { return $false }
        $info = Read-Json $file
        (Get-Property $info 'kind') -eq 'orchestrate-tasks' -and (Get-Property $info 'checkout') -eq $Checkout
    })
}

# --- supervisor agent definition (-InstallAgent) ---
function Get-SupervisorBody {
@'
You supervise the sequential task queue of the repository you are launched from. You work with no prior context: discover everything below yourself.

Discovery
1. Repository: `git rev-parse --show-toplevel`. SecondBrain: the SECONDBRAIN_HOME environment variable (if it is not set, report it and stop). The script is `$env:SECONDBRAIN_HOME\scripts\orchestrate-tasks.ps1`; the tracker and the work folder are found by the script from the Git origin.
2. State: run `pwsh -NoProfile -File <script> -Status`. It prints the latest run (phase, pid alive, current task, counters, notice, last events).

Rules
- You do not execute tasks, change product code, edit the tracker or do the SecondBrain bookkeeping: the script does it after each task, and every task runs in its own fresh headless CLI process.
- Never commit, push, publish or delete. The script commits locally on a queue/* branch and never pushes; the person merges on return.
- Never use git reset, git clean or git stash. Never grant wider tool access on your own: `-ConfirmExtendedTools` only if the person who launched you said so in this session.

Procedure
1. Preview: run the script without -Run and report the tasks selected and skipped. If none is selected, report and stop.
2. If -Status shows phase running with a live pid, a run is active: do not start another. If it shows phase running with a dead pid, the run was cut: starting it again resumes the interrupted task.
3. Start detached from the repository root: `Start-Process pwsh -ArgumentList '-NoProfile','-File',<script>,'-Run' -WorkingDirectory <repository root>` with the parameters you were given (-Provider, -Model, -Effort, -MaxTasks, -TimeoutMinutes, -MaxWaitHours, -ExcludeIds). The script creates the queue branch and holds the power request.
4. Monitor at long intervals (several minutes, never tight polling) with -Status. Phases: running, waiting-quota (waitingUntil), finished. `-Stop` ends the run before the next task: use it only when asked. If the process is gone and the phase is still running, start it once more with the same parameters.
5. Report at every stop and at the end, from -Status, events.jsonl, git log and the tracker only: per task the outcome, the commit, the tracker status and evidence; then skipped, failed and parked (user_required) tasks with their reason, the NOTICE.txt text if present, the branch name and the work folder.
'@
}
function Get-SupervisorTarget([string]$Name) {
    $description = 'Supervises the sequential task queue of this repository (one fresh headless CLI session per tracker task, local commits on a queue branch). Use only when asked to start, check or stop the queue.'
    switch ($Name) {
        'claude' { @{ path = '.claude/agents/task-queue-supervisor.md'; verified = $true; content = "---`nname: task-queue-supervisor`ndescription: `"$description`"`ntools: Bash, Read, Glob, Grep`n---`n`n$(Get-SupervisorBody)`n" } }
        'gemini' { @{ path = '.gemini/agents/task-queue-supervisor.md'; verified = $false; content = "---`nname: task-queue-supervisor`ndescription: `"$description`"`n---`n`n$(Get-SupervisorBody)`n" } }
        'codex' { @{ path = '.codex/task-queue-supervisor.md'; verified = $false; content = "# task-queue-supervisor`n`n$description`n`n$(Get-SupervisorBody)`n" } }
    }
}
if ($InstallAgent) {
    $target = Get-SupervisorTarget $Provider
    $full = Join-Path $Checkout $target.path
    if (Test-Path -LiteralPath $full) {
        [Console]::Error.WriteLine((Get-SBMessage 'orchestrate.agent.exists' @($target.path)))
        [pscustomobject]@{ state = 'exists'; provider = $Provider; path = $target.path; liveVerified = $target.verified } | ConvertTo-Json
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    [IO.File]::WriteAllText($full, $target.content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ state = 'created'; provider = $Provider; path = $target.path; liveVerified = $target.verified; note = 'Not committed; the orchestrator ignores this file when it checks the tree.' } | ConvertTo-Json
    return
}

# --- status and stop ---
if ($Status -or $Stop) {
    $folders = @(Get-RunFolders)
    if (-not $folders.Count) { throw (New-SBError 'orchestrate.run.none' @($Checkout)) }
    $latest = $folders[-1].FullName
    $info = Read-Json (Join-Path $latest 'status.json')
    $alive = Test-ProcessAlive (Get-Property $info 'pid')
    if ($Stop) {
        if ((Get-Property $info 'phase') -ne 'finished') { New-Item -ItemType File -Force -Path (Join-Path $latest 'stop.flag') | Out-Null }
        [pscustomobject]@{ workDir = $latest; phase = $info.phase; pidAlive = $alive; stopFlag = (Test-Path -LiteralPath (Join-Path $latest 'stop.flag')) } | ConvertTo-Json
        return
    }
    $eventsPath = Join-Path $latest 'events.jsonl'
    $recent = if (Test-Path -LiteralPath $eventsPath) { @(Get-Content -LiteralPath $eventsPath -Tail 8 -Encoding utf8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $_ } } | ForEach-Object { "$($_.time) [$($_.event)] $($_.message)" }) } else { @() }
    $noticePath = Join-Path $latest 'NOTICE.txt'
    [pscustomobject]@{
        workDir = $latest; phase = $info.phase; pid = (Get-Property $info 'pid'); pidAlive = $alive
        interrupted = ((Get-Property $info 'phase') -in 'running', 'waiting-quota', 'starting') -and -not $alive
        provider = (Get-Property $info 'provider'); branch = (Get-Property $info 'branch'); current = (Get-Property $info 'current'); waitingUntil = (Get-Property $info 'waitingUntil')
        done = @(Get-Property $info 'done' @()); failed = @(Get-Property $info 'failed' @()); parked = @(Get-Property $info 'parked' @()); skipped = @(Get-Property $info 'skipped' @())
        power = (Get-Property $info 'power'); authorization = (Get-Property $info 'authorization'); updatedAt = (Get-Property $info 'updatedAt')
        notice = $(if (Test-Path -LiteralPath $noticePath) { (Get-Content -LiteralPath $noticePath -Raw -Encoding utf8).Trim() } else { $null })
        recentEvents = $recent
    } | ConvertTo-Json -Depth 6
    return
}

# --- authorization of wider tool access ---
$defaults = @{ PermissionMode = 'acceptEdits' }
$extended = $PSBoundParameters.ContainsKey('PermissionMode') -and $PermissionMode -ne $defaults.PermissionMode
$extended = $extended -or $PSBoundParameters.ContainsKey('AllowedTools') -or $PSBoundParameters.ContainsKey('DisallowedTools')
if ($Pinned) { $extended = [bool]$ExtendedProfile }   # the pinned copy receives every value explicitly: the caller's decision is forwarded
if ($Run -and $extended) {
    if ($Provider -ne 'claude') { throw (New-SBError 'orchestrate.extended.provider') }
    if (-not $ConfirmExtendedTools) { throw (New-SBError 'orchestrate.extended.unconfirmed') }
}

# --- work folder and resume ---
$resume = $null
if (-not $WorkDir) {
    $last = @(Get-RunFolders) | Select-Object -Last 1
    if ($Run -and $last) {
        $lastState = Read-Json (Join-Path $last.FullName 'status.json')
        $lastPhase = [string](Get-Property $lastState 'phase')
        if ($lastPhase -in 'running', 'waiting-quota', 'starting') {
            if (Test-ProcessAlive (Get-Property $lastState 'pid')) { throw (New-SBError 'orchestrate.alive' @((Get-Property $lastState 'pid'), $last.FullName)) }
            $resume = $lastState; $WorkDir = $last.FullName
        }
    }
    if (-not $WorkDir) {
        if (-not $identity) { throw (New-SBError 'orchestrate.identity.missing') }
        Push-Location $Checkout
        try { $init = & pwsh -NoProfile -File (Join-Path $SecondBrain 'scripts\work.ps1') -Repository $identity -Init -Category report -Slug task-run | Out-String | ConvertFrom-Json }
        finally { Pop-Location }
        $WorkDir = $init.root
    }
}
elseif ((Test-Path -LiteralPath (Join-Path $WorkDir 'status.json')) -and $Pinned) {
    $previous = Read-Json (Join-Path $WorkDir 'status.json')
    if ((Get-Property $previous 'kind') -eq 'orchestrate-tasks' -and (Get-Property $previous 'phase') -in 'running', 'waiting-quota', 'starting') { $resume = $previous }
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# --- queue branch, then the pinned copy ---
if ($Run -and -not $Pinned) {
    $current = Get-CurrentBranch
    if ($current -notmatch '^queue/') {
        if ($Branch -and (Test-ProtectedBranch $Branch)) { throw (New-SBError 'orchestrate.branch.protected' @($Branch)) }
        $name = if ($Branch) { $Branch } else { 'queue/{0:yyyyMMdd-HHmm}' -f (Get-SBNow -Local) }
        if (@((Invoke-Git @('status', '--porcelain', '--untracked-files=all')).Text -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\S+\s+"?\.(claude|gemini|codex)/' }).Count) { throw (New-SBError 'orchestrate.branch.dirty') }
        $switch = Invoke-Git @('switch', '-c', $name)
        if ($switch.Code -ne 0) { throw (New-SBError 'orchestrate.branch.failed' @($name, $switch.Text)) }
    }
    $snapshot = Join-Path $WorkDir ('snapshot-{0:yyyyMMddHHmmss}' -f (Get-SBNow -Local))
    New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
    foreach ($item in 'scripts', 'config') { Copy-Item -LiteralPath (Join-Path $SecondBrain $item) -Destination (Join-Path $snapshot $item) -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $SecondBrain 'VERSION') -Destination (Join-Path $snapshot 'VERSION') -Force
    $copy = Join-Path $WorkDir ('orchestrate-tasks.pinned-{0:yyyyMMddHHmmss}.ps1' -f (Get-SBNow -Local))
    Copy-Item -LiteralPath $PSCommandPath -Destination $copy
    $forward = @{ Checkout = $Checkout; WorkDir = $WorkDir; SecondBrain = $SecondBrain; Provider = $Provider; Effort = $Effort; PermissionMode = $PermissionMode
        AllowedTools = $AllowedTools; DisallowedTools = $DisallowedTools; TimeoutMinutes = $TimeoutMinutes; MaxTasks = $MaxTasks; MaxWaitHours = $MaxWaitHours; QuotaLowPercent = $QuotaLowPercent; ScriptsSnapshot = $snapshot
        ExcludePattern = $ExcludePattern; SelfPattern = $SelfPattern; ExcludeIds = $ExcludeIds; OnlyIds = $OnlyIds; Run = $true; Pinned = $true }
    if ($Model) { $forward.Model = $Model }
    if ($TrackerPath) { $forward.TrackerPath = $TrackerPath }
    if ($AgentPath) { $forward.AgentPath = $AgentPath }
    if ($IncludeExcluded) { $forward.IncludeExcluded = $true }
    $forward.HealthChecks = $HealthChecks
    if ($ConfirmExtendedTools) { $forward.ConfirmExtendedTools = $true }
    if ($AllowNoPowerRequest) { $forward.AllowNoPowerRequest = $true }
    if ($extended) { $forward.ExtendedProfile = $true }
    & $copy @forward
    return
}

$eventsFile = Join-Path $WorkDir 'events.jsonl'
$statusFile = Join-Path $WorkDir 'status.json'
$stopFile = Join-Path $WorkDir 'stop.flag'
$noticeFile = Join-Path $WorkDir 'NOTICE.txt'
$state = [ordered]@{ kind = 'orchestrate-tasks'; checkout = $Checkout; phase = 'starting'; pid = $PID; startedAt = (Get-SBNow -Local).ToString('o'); provider = $Provider; model = $Model; effort = $Effort; branch = $null
    current = $null; currentId = $null; done = @(); failed = @(); parked = @(); skipped = @(); waitingUntil = $null; power = $null; authorization = $null; notice = $null; updatedAt = $null }
$resumeId = $null
if ($resume) {
    foreach ($name in 'done', 'failed', 'parked', 'skipped') { $state[$name] = @(Get-Property $resume $name @()) }
    $state.startedAt = [string](Get-Property $resume 'startedAt' $state.startedAt)
    $resumeId = [string](Get-Property $resume 'currentId' '')
}

function Write-State([string]$Phase) {
    if (-not $Run) { return }   # a preview never touches the state of a run
    if ($Phase) { $state.phase = $Phase }
    $state.updatedAt = (Get-SBNow -Local).ToString('o')
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusFile -Encoding utf8
}
function Write-Event([string]$Kind, [string]$Message, $Data = $null) {
    $record = [ordered]@{ time = (Get-SBNow -Local).ToString('o'); event = $Kind; message = $Message }
    if ($null -ne $Data) { $record.data = $Data }
    if ($Run) { ($record | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $eventsFile -Encoding utf8 }
    [Console]::Error.WriteLine("[$Kind] $Message")
}
function Write-Notice([string]$Reason) {
    $text = "Task queue stopped at $((Get-SBNow -Local).ToString('o')): $Reason`nBranch: $($state.branch). Work folder: $WorkDir`nNothing was reverted, reset, cleaned or stashed. Run orchestrate-tasks.ps1 -Status."
    Set-Content -LiteralPath $noticeFile -Value $text -Encoding utf8
    $state.notice = $Reason
    Write-Event 'notice' $Reason
}
function Test-Stop { Test-Path -LiteralPath $stopFile }
function Invoke-Knowledge([string[]]$KArgs) {
    Push-Location $Checkout
    try { $text = & pwsh -NoProfile -File (Join-Path $scriptsDir 'knowledge.ps1') @KArgs 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text } }
    finally { Pop-Location }
}

# --- tracker (read only) ---
function Get-Tasks { @((Read-Json $TrackerPath).tasks) }
function Get-Task([string]$Id) {
    # A task closed as done is moved to the archive by SecondBrain, so the archive is read when the tracker no longer has it.
    $hit = Get-Tasks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $hit -and (Test-Path -LiteralPath $archivePath)) { $hit = @((Read-Json $archivePath).tasks) | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
    $hit
}
function Test-DependencyDone([string]$Id, $Tasks, $Archive) {
    $hit = $Tasks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $hit -and $Archive) { $hit = $Archive | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }
    [bool]($hit -and $hit.status -eq 'done')
}
function Test-SelfEditing($task) {
    $text = "$($task.title) $(Get-Property $task 'description' '') $(@($task.acceptance) -join ' ')"
    [bool]($SelfPattern -and $text -match $SelfPattern)
}
$script:attempts = @{}
# Same exclusions as the runner (SecondBrain.TaskRunner): final qualification, on-request work and product coordination are never queued.
$excludedStreams = @('qualifica-finale', 'intervento-su-richiesta', 'coordinamento-prodotti', 'final-qualification', 'on-request', 'product-coordination')
function Get-Queue {
    $tasks = Get-Tasks
    $archive = if (Test-Path -LiteralPath $archivePath) { @((Read-Json $archivePath).tasks) } else { @() }
    $queue = foreach ($task in $tasks) {
        if ($task.execution -ne 'autonomous' -or $task.status -notin 'todo', 'in_progress') { continue }
        if ($OnlyIds.Count -and $task.id -notin $OnlyIds -and "#$($task.seq)" -notin $OnlyIds) { continue }
        if ($task.id -in $ExcludeIds -or $task.id -in $state.failed -or $task.id -in $state.done -or $task.id -in $state.parked -or ($script:attempts[$task.id] -ge 2)) { continue }
        $ext = Get-Property $task 'extensions'
        $stream = [string](Get-Property $ext 'stream' '')
        if ($stream -in $excludedStreams) { continue }
        $unmet = @(@(Get-Property $task 'dependencies' @()) | Where-Object { -not (Test-DependencyDone $_.id $tasks $archive) })
        if ($unmet.Count) { continue }
        # A task waiting for a person is not queued (same as the runner); screen-bound work is filtered by -ExcludePattern.
        if ([string](Get-Property $ext 'awaiting' '')) { continue }
        $haystack = "$($task.title) $(Get-Property $task 'blocker' '') $(@(Get-Property $ext 'requires' @()) -join ' ')"
        if (-not $IncludeExcluded -and $ExcludePattern -and $haystack -match $ExcludePattern) {
            if ($task.id -notin $state.skipped) { $state.skipped += $task.id; Write-Event 'skip' "#$($task.seq) matches the screen/interactive filter" }
            continue
        }
        $task
    }
    # The interrupted task first, then ordinary tasks, then the tasks that edit the orchestrator or the runner (ordered last).
    @($queue | Sort-Object @{ e = { if ($resumeId -and $_.id -eq $resumeId) { 0 } else { 1 } } }, @{ e = { if (Test-SelfEditing $_) { 1 } else { 0 } } }, { [string]$_.priority }, { [int]$_.seq })
}

function New-Prompt($task, [bool]$Resuming = $false) {
    $acceptance = (@($task.acceptance) | ForEach-Object { "- $_" }) -join "`n"
    $deps = (@(Get-Property $task 'dependencies' @()) | ForEach-Object { $_.id }) -join ', '
    $ext = Get-Property $task 'extensions'
    $resumeNote = if ($Resuming) { "`nRESUME: a previous session on this task was cut. The working tree holds its partial work: inspect it with git status and git diff, continue from it, and never reset, clean or stash.`n" } else { '' }
    @"
You are executing ONE tracker task in a fresh session for the repository at $Checkout. Do only this task.
$resumeNote
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
The orchestrator also records the run itself (output log, commit) as evidence and runs the health check after you finish.
Forbidden: git commit, push, tag, reset, clean, rebase, deleting files or branches, publishing anything. The orchestrator commits your changes after you finish; leave them in the working tree.
Finish with at most 10 lines: outcome, evidence references, what is left, any blocker.
"@
}

# --- agent process (Claude Code, Codex, Gemini CLI through the adapters) ---
function Resolve-Agent {
    $info = Get-SBAgentProvider $Provider
    $executable = Resolve-SBAgentExecutable $(if ($AgentPath) { $AgentPath } else { $info.command })
    if (-not $executable) { throw (New-SBError 'orchestrate.agent.missing' @($info.name)) }
    $executable
}
function Get-AgentArguments($Executable) {
    if ($Provider -eq 'claude') {
        $list = @('-p')
        if ($Model) { $list += @('--model', $Model) }
        return $list + @('--effort', $Effort, '--permission-mode', $PermissionMode, '--output-format', 'stream-json', '--verbose', '--allowedTools') + $AllowedTools + @('--disallowedTools') + $DisallowedTools
    }
    $capabilities = Get-SBAgentCapabilities -Provider $Provider -BrainRoot $SecondBrain -Executable $Executable
    @((New-SBAgentInvocation -Provider $Provider -Capabilities $capabilities -Model $Model -Effort $Effort).arguments)
}
function ConvertTo-ResetTime($Value) {
    if ($null -eq $Value) { return $null }
    try { [DateTimeOffset]$Value } catch { $null }
}
function Read-Outcome([string]$OutFile, $Process) {
    $o = [ordered]@{ result = $null; isError = $false; quota = $false; resetAt = $null; text = '' }
    if ($Provider -ne 'claude') {
        $limit = Get-SBAgentLimitState -Provider $Provider -Output $Process.output -ErrorOutput $Process.error -ExitCode $Process.exitCode
        if ($limit -and $limit.state -eq 'quota') { $o.quota = $true; $o.resetAt = ConvertTo-ResetTime $limit.resetAt }
        $o.isError = ($null -ne $Process.exitCode -and $Process.exitCode -ne 0)
        $o.text = [string](Get-SBAgentFinalOutput $Process.output)
        if ($o.text.Length -gt 600) { $o.text = $o.text.Substring($o.text.Length - 600) }
        return [pscustomobject]$o
    }
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
    $now = (Get-SBNow -Local)
    $until = if ($OutcomeResetAt -and $OutcomeResetAt -gt $now) { $OutcomeResetAt.AddSeconds(60) } else { $now.AddMinutes(30) }
    if (($until - $now).TotalHours -gt $script:waitBudgetHours) { return $false }
    $script:waitBudgetHours -= ($until - $now).TotalHours
    $state.waitingUntil = $until.ToString('o'); Write-State 'waiting-quota'
    Write-Event 'quota' "Waiting for the quota reset until $($until.ToString('o'))"
    while ((Get-SBNow -Local) -lt $until) {
        if (Test-Stop) { return $false }
        Start-Sleep -Seconds 30
    }
    $state.waitingUntil = $null
    $true
}

function Get-QuotaDecision {
    # #668: quota read now, before each task. Providers without a source (or any read failure) are 'unknown' and never fail the run.
    try {
        $observation = Get-SBRunnerQuotaObservation $SecondBrain (Get-SBHostId) $Provider
        $quota = Get-SBAgentQuota -Provider $Provider -Observation $observation
    }
    catch { $quota = [ordered]@{ provider = $Provider; state = 'unknown'; resetAt = $null; source = 'none'; reason = 'read-failed'; windows = @() } }
    $decision = Get-SBQueueQuotaDecision -Quota $quota -LowPercent $QuotaLowPercent
    $state.quota = [ordered]@{ level = $decision.level; source = $quota.source; resetAt = $decision.resetAt; readAt = (Get-SBNow -Local).ToString('o') }
    Write-Event 'quota-check' "Quota before the next task ($Provider): $($decision.level)$(if ($decision.reason) { ' - ' + $decision.reason })" @{ level = $decision.level; source = $quota.source; resetAt = $decision.resetAt }
    $decision
}

function Invoke-AgentTask($task, [bool]$Resuming) {
    $stamp = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-SBNow -Local), $task.seq
    $promptFile = Join-Path $WorkDir "prompt-$stamp.txt"
    $outFile = Join-Path $WorkDir "out-$stamp.jsonl"
    $prompt = New-Prompt $task $Resuming
    $prompt | Set-Content -LiteralPath $promptFile -Encoding utf8
    $executable = Resolve-Agent
    $process = Invoke-SBAgentProcess -Executable $executable -Arguments (Get-AgentArguments $executable) -Prompt $prompt -WorkingDirectory $Checkout -TimeoutSeconds ($TimeoutMinutes * 60) -OutputLog $outFile -TickSeconds 0
    $timedOut = $process.state -eq 'timeout'
    [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $process.exitCode }); TimedOut = $timedOut; Outcome = (Read-Outcome $outFile $process); OutFile = $outFile }
}

$agentFilePattern = '^\.(claude/agents|gemini/agents|codex)/task-queue-supervisor'
function Get-ChangedPaths {
    $status = Invoke-Git @('status', '--porcelain=v1', '-z', '--untracked-files=all')
    if ($status.Code -ne 0) { throw (New-SBError 'orchestrate.git.status' @($status.Text)) }
    @($status.Text -split "`0" | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) } | Where-Object { $_ -notmatch $agentFilePattern })
}

# --- health check and the SecondBrain scripts manifest ---
function Get-ScriptsManifest {
    $manifest = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $SecondBrain 'scripts') -File -Include '*.ps1', '*.psm1' -Recurse) {
        $manifest[$file.FullName.Substring($SecondBrain.Length)] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $manifest
}
$healthSet = @($HealthChecks -split ',')
# The repository can already fail a check for reasons that are not the run's (for example advisory memory notices in -Check): the exit codes
# at the start are the baseline, and only a check that passed at the start can fail the run. A failing -Quick is repeated once.
$script:healthBaseline = @{}
function Invoke-SelfCheck([string]$Name) {
    $script = if ($Name -eq 'quick') { 'test-secondbrain.ps1' } else { 'secondbrain.ps1' }
    $switchName = if ($Name -eq 'quick') { '-Quick' } else { '-Check' }
    $text = & pwsh -NoProfile -File (Join-Path $scriptsDir $script) $switchName 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $Name -eq 'quick') { $text = & pwsh -NoProfile -File (Join-Path $scriptsDir $script) $switchName 2>&1 | Out-String; $code = $LASTEXITCODE }
    [pscustomobject]@{ Code = $code; Last = ($text.Trim() -split "`n")[-1].Trim() }
}
function Get-HealthBaseline {
    foreach ($name in 'quick', 'check') {
        if ($name -in $healthSet) { $script:healthBaseline[$name] = (Invoke-SelfCheck $name).Code }
    }
    if ($script:healthBaseline.Count) { Write-Event 'health-baseline' 'Exit codes of the self checks at the start of the run' $script:healthBaseline }
}
function Test-Health([string]$Label) {
    $problems = @()
    try { [void](Get-Tasks) } catch { $problems += "tracker unreadable: $($_.Exception.Message)" }
    if (-not $problems.Count -and 'tasks' -in $healthSet) {
        $tasks = Invoke-Knowledge @('-Tasks')
        if ($tasks.Code -ne 0) { $problems += "knowledge.ps1 -Tasks exit $($tasks.Code)" }
    }
    foreach ($name in 'quick', 'check') {
        if ($name -notin $healthSet) { continue }
        $result = Invoke-SelfCheck $name
        if ($result.Code -ne 0 -and $script:healthBaseline[$name] -eq 0) { $problems += "$name exit $($result.Code): $($result.Last)" }
    }
    $now = Get-ScriptsManifest
    $changed = @($now.Keys | Where-Object { $script:scriptsManifest[$_] -ne $now[$_] })
    if ($changed.Count) {
        # With a snapshot (#665) the bookkeeping and the checks above ran with the scripts of the start, so this is informational only.
        $note = if ($ScriptsSnapshot) { "(informational: bookkeeping and checks used the snapshot taken at start)" } else { "(the checks above ran with them)" }
        Write-Event 'scripts-changed' "$($changed.Count) SecondBrain script(s) changed since the run started $note" @($changed | Select-Object -First 10)
    }
    $script:scriptsManifest = $now
    [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems; Label = $Label }
}

# --- main ---
$queue = @(Get-Queue)
Write-Event 'selection' "$($queue.Count) task(s) selected" @($queue | ForEach-Object { "#$($_.seq) $($_.title)$(if (Test-SelfEditing $_) { ' [edits the orchestrator or the runner: ordered last]' })" })
if (-not $Run) {
    foreach ($task in $queue) { "--- #$($task.seq) $($task.id)"; New-Prompt $task }
    Write-State 'preview'
    return
}
if (Test-Path -LiteralPath $noticeFile) { Remove-Item -LiteralPath $noticeFile -Force }   # the notice of a previous run in the same folder is not this run's
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force; Write-Event 'stop-flag-cleared' 'A stop.flag left by a previous run was removed at start' }
$state.branch = Get-CurrentBranch
if (Test-ProtectedBranch $state.branch) { throw (New-SBError 'orchestrate.branch.protected' @($state.branch)) }
$state.authorization = [ordered]@{ profile = $(if ($extended) { 'extended' } else { 'standard' }); confirmed = [bool]$ConfirmExtendedTools; confirmedBy = $env:USERNAME
    at = (Get-SBNow -Local).ToString('o'); permissionMode = $PermissionMode; allowedTools = $AllowedTools; disallowedTools = $DisallowedTools; commitPushDelete = 'forbidden' }
$power = Enter-SBRunnerPowerRequest -Reason 'SecondBrain orchestrate-tasks queue'
$state.power = [ordered]@{ supported = $power.supported; acquired = $power.acquired; error = $power.error }
if ($power.supported -and -not $power.acquired -and -not $AllowNoPowerRequest) {
    Write-Notice (Get-SBMessage 'orchestrate.power.refused' @($power.error))
    Write-State 'finished'
    throw (New-SBError 'orchestrate.power.refused' @($power.error))
}
$script:scriptsManifest = Get-ScriptsManifest
if ($ScriptsSnapshot) { Write-Event 'snapshot' "Bookkeeping and health checks run from the snapshot $ScriptsSnapshot against the live dossier (SECONDBRAIN_BRAIN_ROOT)" }
else { Write-Event 'snapshot' 'No snapshot (resumed or started without one): the live scripts are used and only the SHA-256 manifest guards them' }
Get-HealthBaseline
$script:waitBudgetHours = $MaxWaitHours
$consecutiveFailures = 0
$executed = 0
Write-Event 'run' "Run on branch $($state.branch) with $Provider$(if ($resume) { ' (resuming a cut run)' })"
Write-State 'running'
try {
    while ($true) {
        if (Test-Stop) { Write-Event 'stop' 'stop.flag found'; break }
        if ($MaxTasks -gt 0 -and $executed -ge $MaxTasks) { Write-Event 'stop' 'MaxTasks reached'; break }
        if ($consecutiveFailures -ge 3) { Write-Notice 'Three consecutive failures'; break }
        $queue = @(Get-Queue)
        if ($queue.Count -eq 0) { Write-Event 'stop' 'No eligible task left'; break }
        $task = $queue[0]
        $resuming = [bool]($resumeId -and $task.id -eq $resumeId)
        $clean = Invoke-Git @('status', '--porcelain', '--untracked-files=all')
        $dirty = @($clean.Text -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\S+\s+"?\.(claude/agents|gemini/agents|codex)/task-queue-supervisor' })
        if ($dirty.Count -and -not $resuming) { Write-Notice "Working tree not clean before #$($task.seq); nothing is started"; $state.failed += "dirty-before-#$($task.seq)"; break }
        if ($resuming) { Write-Event 'resume' "#$($task.seq) resumes the interrupted task ($($dirty.Count) path(s) left by the cut session)" }
        $quotaDecision = Get-QuotaDecision
        if ($quotaDecision.action -eq 'wait') {
            Write-Event 'quota' "Quota $($quotaDecision.level) before #$($task.seq): waiting for the reset"
            $resetAt = if ($quotaDecision.resetAt) { ConvertTo-ResetTime $quotaDecision.resetAt } else { $null }
            if (Wait-ForReset $resetAt) { continue }
            Write-Notice "Quota $($quotaDecision.level) and the reset is beyond -MaxWaitHours (or the wait was stopped); #$($task.seq) not started"; break
        }
        $resumeId = $null
        $state.current = "#$($task.seq) $($task.id)"; $state.currentId = $task.id; Write-State 'running'
        Write-Event 'start' "#$($task.seq) $($task.title)"
        [void](Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Status', 'in_progress', '-StateReason', 'Started by orchestrate-tasks.ps1'))
        $attempt = Invoke-AgentTask $task $resuming
        if ($attempt.Outcome.quota) {
            Write-Event 'quota' "Quota limit during #$($task.seq)"
            if (Wait-ForReset $attempt.Outcome.resetAt) { continue }
            Write-Notice 'Quota wait exceeded the budget or was stopped'; break
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
        # local commit of the changed paths (the rollback point), never a push
        $commitHash = $null
        $paths = @(Get-ChangedPaths)
        if ($paths.Count) {
            $forbidden = @($paths | Where-Object { $_ -match '(^|/)\.claude/|\.pfx$|\.snk$|(^|/)secrets?\.|\.env$' })
            if ($forbidden.Count) { Write-Notice "#$($task.seq) touched forbidden paths, nothing committed: $($forbidden -join ', ')"; $state.failed += "forbidden-#$($task.seq)"; break }
            [void](Invoke-Git (@('add', '--') + $paths))
            $title = ($task.title -replace '^#\d+\s*\W+\s*', '')
            $commit = Invoke-Git @('commit', '-m', "$title (#$($task.seq))", '-m', "Executed by orchestrate-tasks.ps1 ($Provider).")
            if ($commit.Code -ne 0) { Write-Notice "commit failed: $($commit.Text)"; break }
            $commitHash = (Invoke-Git @('rev-parse', '--short', 'HEAD')).Text.Trim()
            Write-Event 'commit' "#$($task.seq) committed locally ($commitHash)"
        }
        else { Write-Event 'commit' "#$($task.seq) no file changes" }
        # bookkeeping by the script: the run itself is evidence of the task, whatever the session recorded
        $reference = "report/$(Split-Path -Leaf $WorkDir)/$(Split-Path -Leaf $attempt.OutFile)"
        $summary = ("session $(if ($ok) { 'ended' } else { 'failed' }); $(if ($commitHash) { "commit $commitHash on $($state.branch)" } else { 'no file changes' }); $($attempt.Outcome.text)" -replace '\s+', ' ')
        if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300) }
        # The tracker accepts only reference|outcome with outcome passed, failed, partial or unverified; the text stays in the event.
        $outcomeWord = if (-not $ok) { 'failed' } elseif ($after.status -eq 'done') { 'passed' } else { 'unverified' }
        $recorded = Invoke-Knowledge @('-UpdateTaskId', $task.id, '-Evidence', "$reference|$outcomeWord")
        if ($recorded.Code -eq 0 -and $recorded.Text -match '"state":\s*"applied"') { Write-Event 'evidence' "#$($task.seq) run evidence recorded in the tracker ($outcomeWord)" @{ summary = $summary } }
        else { Write-Event 'evidence' "#$($task.seq) run evidence not accepted by the tracker: $(($recorded.Text.Trim() -split "`n")[0]); see $reference" @{ summary = $summary } }
        $state.current = $null; $state.currentId = $null
        $health = Test-Health "after #$($task.seq)"
        if (-not $health.Ok) {
            Write-Event 'health' "Health check failed after #$($task.seq)" $health.Problems
            Write-Notice "Health check failed after #$($task.seq): $($health.Problems -join '; ')"
            $state.failed += "health-#$($task.seq)"
            break
        }
        Write-Event 'health' "Health check passed after #$($task.seq)"
        Write-State 'running'
    }
}
catch {
    Write-Notice "Unexpected error: $($_.Exception.Message)"
    throw
}
finally {
    [void](Exit-SBRunnerPowerRequest)
    $state.current = $null
    Write-State 'finished'
    Write-Event 'summary' "done=$(@($state.done).Count) failed=$(@($state.failed).Count) parked=$(@($state.parked).Count) skipped=$(@($state.skipped).Count)"
}
