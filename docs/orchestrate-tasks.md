# orchestrate-tasks.ps1: sequential task queue with `claude -p`

[Italiano](orchestrate-tasks.it.md)

`scripts/orchestrate-tasks.ps1` runs the autonomous tracker tasks of one repository one at a time, each in a fresh `claude -p` process, and commits locally after each. It is independent of `run-ready-tasks.ps1`: use it when the tasks themselves change the runner.

- Finds the checkout (Git root of the current directory), SecondBrain (`SECONDBRAIN_HOME`, else the folder above the script) and the dossier (Git `origin` identity in `01-projects/*/repository.json`); creates its work folder with `work.ps1` when `-WorkDir` is omitted.
- Preview by default; `-Run` starts a pinned copy of the script. Defaults: `-Model sonnet -Effort medium -PermissionMode acceptEdits`, an explicit `-AllowedTools` list, `-DisallowedTools` for git commit, push, tag, reset, clean, rebase, `rm`, `Remove-Item`, 45 minutes per task.
- Per task: clean tree required, task marked `in_progress`, session run, a `done` without evidence reopened, a task that ends without a result parked as `user_required`, then a local commit of the changed paths (never a push). Quota limits wait for the reset (`-MaxWaitHours`) and retry; three consecutive failures stop the run.
- Tasks that need a screen (computer-use) or an installer are skipped by `-ExcludePattern`; `-IncludeExcluded` lifts that, and such a session ends parked.
- State: `status.json`, `events.jsonl`, `stop.flag` in the work folder.

## Prompt: create the launcher agent in any repository

```text
Create the project subagent "task-runner" in .claude/agents/task-runner.md of this repository (frontmatter: name task-runner, description "Launches and monitors the sequential task orchestrator for this repository (one claude -p session per tracker task, local commit after each). Use only when the parent explicitly asks to start or check it.", tools "*"). Do not launch it and do not commit the file.

Role: you launch and monitor $env:SECONDBRAIN_HOME\scripts\orchestrate-tasks.ps1 (if the variable is not set, report it and stop). The script runs the autonomous tracker tasks of the current repository one at a time, each in a fresh `claude -p`, with a local commit after each. You do not execute tasks and you do not change product code. The script finds the checkout, the dossier (from the origin identity) and the work folder by itself, and with -Run it runs a pinned copy of itself.

The agent body must prescribe:
1. Inputs from the caller (if missing, report what is missing and stop; do not ask the user): model, effort, MaxTasks (0 = no limit), timeout per task in minutes, maximum hours of waiting for the quota limit, and whether to lift the screen-task filter (-IncludeExcluded, default no). Script defaults: sonnet, medium, 45 minutes, 6 hours. Permissions are granted by the caller upstream; -AllowedTools and -DisallowedTools are script parameters and the default forbids git commit, push, tag, reset, clean, rebase, rm and Remove-Item in the task sessions.
2. Start: preview without -Run from the repository root and report the tasks selected and the tasks skipped by the filter; if none is selected, report and stop. Then check that `git status --porcelain` is empty (the script ignores .claude/agents/) and that no orchestrator is alive (status.json of the latest task-run folder: phase running with a live pid = stop and report). Launch detached with Start-Process pwsh -NoProfile -File <script> -Run with the received parameters, from the repository root; record the pid and the work folder.
3. Monitoring: read status.json and the tail of events.jsonl of the work folder at long intervals (several minutes, waits in the background, never tight polling). Phases: running, waiting-quota (waitingUntil), finished. stop.flag in the work folder stops the run before the next task: create it only if the caller asks. If the process is gone and the phase is still running (for example a Claude update cut it), report and restart once with the same parameters: the script reselects the tasks that are still open.
4. Report at every stop and at the end: per task the outcome, commit hash (git log), tracker status afterwards, evidence; then skipped, failed and parked (user_required) tasks with the reason from events.jsonl, quota state and the work folder path. Report only what you read from status.json, events.jsonl, git and the tracker.
5. Rules: never commit, push, publish or delete yourself (the script commits locally only the paths changed by the task and never pushes); dossier writes only through SecondBrain scripts, normally none; do not delegate to other agents.

If a .claude/agents/task-runner.md already exists, do not overwrite it: compare it and propose the differences.
```

## Note: full permissions for the runner

The runner (`run-ready-tasks.ps1`) starts agents with a fixed permission profile: file edits in the checkout, no Git history changes, no deletion. Sessions started in chat can have broader permissions granted by the user.

To do: let the runner run with the same permissions as in chat, only after prior authorization or an explicit runner setting.

- Add a runner setting (per run, in the orchestrator app and as a `run-ready-tasks.ps1` parameter) that selects the permission profile: standard (today) or extended (as in chat).
- Require an explicit confirmation before the run for the extended profile, and record the profile, who confirmed and when in `status.json` and the run report.
- `orchestrate-tasks.ps1` already exposes this through `-PermissionMode`, `-AllowedTools` and `-DisallowedTools`: widen them only with the user's prior authorization.
- Keep the forbidden actions of the repository directives (commit, push, publication, deletion) outside the extended profile unless the authorization names them.
