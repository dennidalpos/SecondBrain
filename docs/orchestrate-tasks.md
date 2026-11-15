# orchestrate-tasks.ps1: sequential task queue on a queue branch

[Italiano](orchestrate-tasks.it.md)

`scripts/orchestrate-tasks.ps1` runs the autonomous tracker tasks of one repository one at a time, each in a fresh headless agent process (Claude Code, Codex or Gemini CLI through `SecondBrain.AgentAdapters`), and commits locally after each. It is independent of `run-ready-tasks.ps1`: use it when the tasks themselves change the runner.

- Finds the checkout (Git root of the current directory), SecondBrain (`SECONDBRAIN_HOME`, else the folder above the script) and the dossier (Git `origin` identity in `repository.json` under `01-projects`, `02-areas` or `03-resources`); creates its work folder with `work.ps1` (`.runtime/hosts/<host>/repos/<repo>/report/<date>-task-run`).
- Preview by default. `-Run` creates a `queue/<yyyyMMdd-HHmm>` branch (or `-Branch`; never `master` or `main`; skipped when already on a `queue/*` branch), then starts a pinned copy of the script. No push, ever.
- `-Provider claude|codex|gemini` (default `claude`), `-Model`, `-Effort`, `-AgentPath`, 45 minutes per task. Tool access of the task sessions: `-PermissionMode acceptEdits`, an explicit `-AllowedTools` list and a `-DisallowedTools` list (git commit, push, tag, reset, clean, rebase, `rm`, `Remove-Item`). Changing any of the three needs `-ConfirmExtendedTools` (Claude Code only); the profile, the confirmation and the time are recorded in `status.json`.
- Per task: clean tree required (except the interrupted task on resume), task marked `in_progress`, session run, a `done` without evidence reopened, a task that ends without a result parked as `user_required`, a local commit of the changed paths (the rollback point), run evidence offered to the tracker, then the health check: tracker readable, `knowledge.ps1 -Tasks`, `test-secondbrain.ps1 -Quick`, `secondbrain.ps1 -Check` (`-HealthChecks` selects a subset). A failed check stops the run with a `NOTICE.txt`; nothing is reverted, reset, cleaned or stashed.
- Selection: autonomous, `todo` or `in_progress`, dependencies done, not in the excluded streams of the runner, not waiting for a person, not screen-bound (`-ExcludePattern`, lifted by `-IncludeExcluded`). Tasks that edit the orchestrator or the runner themselves (`-SelfPattern`) are ordered last.
- Quota limits wait for the reset (`-MaxWaitHours`) and retry; three consecutive failures stop the run. On Windows the run holds a system-required power request (no idle sleep); if it is refused the run does not start unless `-AllowNoPowerRequest`.
- `-Status` prints the latest run (phase, pid alive, interrupted, current task, counters, notice, last events); `-Stop` creates `stop.flag` so the run ends before the next task.
- Resume: a run cut while `running` (pid gone) is resumed by running `-Run` again. The work folder and counters come from `status.json`; the interrupted task goes first, its dirty tree is accepted for that task only, and its prompt says to continue the partial work.
- `-InstallAgent -Provider claude|codex|gemini` writes a context-free supervisor agent definition into the checkout and never overwrites an existing file. Only the Claude Code format (`.claude/agents/task-queue-supervisor.md`) is verified; the Codex and Gemini files are plain definitions to adapt.
- Limits: the SecondBrain scripts cannot be pinned (the brain root is the parent of `scripts/` and the dossier write guard refuses junctions), so their SHA-256 manifest is taken at start and a change is reported as `scripts-changed` after each task. The health check compares `-Quick` and `-Check` with their exit codes at the start of the run, so a repository that already fails one of them is not stopped by it. Extended tool access works with Claude Code only. The quota is not read before each task.

## Note: full permissions for the runner

The runner (`run-ready-tasks.ps1`) starts agents with a fixed permission profile: file edits in the checkout, no Git history changes, no deletion. Sessions started in chat can have broader permissions granted by the user.

To do: let the runner run with the same permissions as in chat, only after prior authorization or an explicit runner setting.

- Add a runner setting (per run, in the orchestrator app and as a `run-ready-tasks.ps1` parameter) that selects the permission profile: standard (today) or extended (as in chat).
- Require an explicit confirmation before the run for the extended profile, and record the profile, who confirmed and when in `status.json` and the run report.
- `orchestrate-tasks.ps1` already exposes this through `-PermissionMode`, `-AllowedTools` and `-DisallowedTools`: widen them only with the user's prior authorization.
- Keep the forbidden actions of the repository directives (commit, push, publication, deletion) outside the extended profile unless the authorization names them.
