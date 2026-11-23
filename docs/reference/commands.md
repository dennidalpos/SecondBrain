# sb command reference

Every `sb` command, its mode, the channel it uses and the script behind it. **MCP is the preferred channel**: where a command has an MCP tool the agent calls it first, and falls back to the CLI script when the MCP server is unavailable or not aligned (`sb mcp status` checks it, `sb mcp realign` fixes it). Commands marked CLI only have no MCP tool.

The menus are `sb home` (daily work), `sb maintenance` and `sb mcp`; the screens are shown in the language the user writes in, while the commands, prompt codes and paths stay as written here. This page is checked against the command registry by `scripts/test-secondbrain-prompts.ps1`.

## Commands

| Command | Menu | What it does | Mode | Channel | Script |
|---|---|---|---|---|---|
| `sb home` | home | This menu: repository state, the active channel (MCP or CLI), the commands by section and the link to the full catalog. | read | MCP: get_prompt_home; CLI fallback | `scripts/prompts.ps1` |
| `sb prompt` | home | Same screen as sb home (kept so existing instructions keep working); the other sb prompt forms list, show and run prompt cards. | read | CLI only | `scripts/prompts.ps1` |
| `sb prompt list` | home | Compact list of all prompts, one line each, by area. | read | MCP: list_prompts; CLI fallback | `scripts/prompts.ps1 -List -Compact` |
| `sb prompt area AREA` | home | Prompts of one area with ID, scope and requirements (area id or prefix: test, TST, system, SYS). | read | MCP: list_prompts; CLI fallback | `scripts/prompts.ps1 -List -Category AREA` |
| `sb prompt show KEY` | home | Full card of a prompt; KEY is an ID (pmt-…) or code. | read | MCP: get_prompt; CLI fallback | `scripts/prompts.ps1 -Show -Prompt KEY` |
| `sb prompt KEY: objective` | home | Composes the prompt with the repository context and runs it within the session permissions. | per the card | MCP: get_prompt; CLI fallback | `scripts/prompts.ps1 -Compose -Prompt KEY -Objective TEXT` |
| `sb activate` | maintenance | workstation.activate: read-only discovery, map of repositories and IDEs, activation after confirmation. Alias: sb activate. | write | CLI only | `scripts/secondbrain.ps1 -Setup -Interactive` |
| `sb setup` | maintenance | workstation.setup: guided first-run setup of SecondBrain, IDE, agent, directives and MCP, with optional features proposed from the state. Alias: sb configura. | write | CLI only | `scripts/setup-status.ps1` |
| `sb skills` | home | project.skills: analyzes the project, proposes skills from its facts and installs the selected ones for Claude Code, Codex or Antigravity at project or user scope, with preview and confirmation (scripts/skills.ps1). | write | CLI only | `scripts/skills.ps1` |
| `sb check` | maintenance | workstation.check: checks the alignment of managed assets without fixing. Alias: sb check. | verify | CLI only | `scripts/secondbrain.ps1 -Check` |
| `sb sync` | maintenance | Applies the approved texts to managed assets and proposes the new ones, preserving conflicts. Alias: sb sync. | write | CLI only | `scripts/secondbrain.ps1 -Sync` |
| `sb compact` | maintenance | dossier.compact, mechanical and lossless: marks the dated sections older than 30 days as history tier and reports the initial context usage; no model. It runs by itself at the end of every task; originals stay in history/compaction and the history stays readable by level. | write | CLI only | `scripts/knowledge.ps1 -Compact -Mechanical [-Apply] | -Compact -CandidatePath FILE` |
| `sb compact ai` | maintenance | Compacts the dossier further with the light model of the provider you pick (claude haiku, gemini flash-lite, codex low effort): read-only run, preview of the candidate, then -Apply with your -ReviewNote; originals are archived by hash. | write | CLI only | `scripts/compact-ai.ps1 -Provider claude|codex|gemini [-Apply -ReviewNote TEXT]` |
| `sb runner` | home | Asks with a multiple choice for the desktop runner (recommended) or the command line, then opens the runner on the current repository with scripts/runner.ps1 -Mode auto/gui/cli: the desktop app is built when stale and, if it cannot open, the command line takes over by itself (preview, then runner.choice). | run | CLI only | `scripts/runner.ps1` |
| `sb runner gui` | home | Runner in the desktop app (Orchestrator); the app is built when stale. Same as sb runner with the desktop choice. | run | CLI only | `scripts/runner.ps1 -Mode gui` |
| `sb runner cli` | home | Runner on the command line, without the desktop app. Same as sb runner with the command-line choice. | run | CLI only | `scripts/runner.ps1 -Mode cli` |
| `sb queue` | home | Alternative to the runner, only for when many autonomous tasks change the main runner itself (orchestrate-tasks.ps1). Before starting, the agent asks with the structured question tool for the provider (claude, codex or gemini), then the model and the effort that provider offers, and passes them as -Provider, -Model, -Effort. Preview by default; -Start runs it detached on a queue/<date> branch with local commits only; -OnlyIds, -ExcludeIds, -MaxTasks. | run | CLI only | `scripts/queue.ps1 [-Start] [-Provider claude|codex|gemini] [-OnlyIds IDS] [-ExcludeIds IDS] [-MaxTasks N]` |
| `sb queue status` | home | Shows the latest queue run of the repository (phase, pid alive, current task, counters, notice, last events). Nothing is written. | read | CLI only | `scripts/queue.ps1 -Status` |
| `sb queue stop` | home | Asks the active queue run of the repository to end before the next task (stop.flag). | write | CLI only | `scripts/queue.ps1 -Stop` |
| `sb reconcile tasks` | home | tasks.reconcile: plans the reconciliation of conflicting or invalid queued writes and orphan receipts of the repository; -Apply retires duplicates and orphans and re-plans safe stale requests, -Decide ID=OPTION executes the choice the owner made. Nothing is deleted. | write | CLI only | `scripts/reconcile-tasks.ps1 [-Apply] [-Decide ID=OPTION]` |
| `sb stop` | home | session.stop: stops the agent, saves the session in the dossier (handoff report, tracker, next step) and prepares it to be resumed from another IDE or account with session.resume. | write | CLI only | `scripts/prompts.ps1 -Compose -Prompt session.stop` |
| `sb tasks` | home | Lists the open tasks of the repository tracker; add -ReadyOnly for the tasks the runner can take. Nothing is written. | read | MCP: get_ready_tasks, get_task; CLI fallback | `scripts/knowledge.ps1 -Tasks [-ReadyOnly]` |
| `sb next` | home | Proposes the next steps for the repository after a task or a run, each with the reason. Nothing is written. | read | CLI only | `scripts/next-steps.ps1` |
| `sb pending` | home | Lists the queued dossier writes of the repository (applied, pending, conflict, invalid). Nothing is integrated. | read | CLI only | `scripts/knowledge.ps1 -PendingWrites` |
| `sb pending flush` | home | Integrates the queued dossier writes of the own dossier; conflicts stay queued (resolve them with sb reconcile tasks). | write | CLI only | `scripts/knowledge.ps1 -FlushPending` |
| `sb runner status` | home | Shows whether the task runner of the repository is working, stalled, finished or orphaned and what the agent did last; -List shows the recent runs, -Stop stops the active one. | read | MCP: get_runner_status; CLI fallback | `scripts/runner-status.ps1 [-List|-Follow|-Stop]` |
| `sb publish check` | home | Scans the working tree, index and history of the repository for private data and secrets before a push. Nothing is changed. | verify | MCP: check_publication; CLI fallback | `scripts/publication.ps1 -RepositoryPath .` |
| `sb grants` | home | Lists the scoped MCP write grants of the workstation (repository, state, expiry, operations). Granting and revoking stay with the owner in the terminal (mcp-write.ps1 -Grant, -Revoke). | read | CLI only | `scripts/mcp-write.ps1 -Grants` |
| `sb projects` | maintenance | Lists the repositories bound on this workstation with the task counts of each tracker and the gitUpdate preference. Nothing is written. | read | CLI only | `scripts/projects.ps1 -List` |
| `sb status` | maintenance | Shows the workstation setup state: bindings, IDEs and accounts. Nothing is written. | read | CLI only | `scripts/secondbrain.ps1 -Setup -Status` |
| `sb ides` | maintenance | Checks the global instructions of the IDEs listed in the workstation map, without fixing them. | verify | MCP: list_ides; CLI fallback | `scripts/ide-map.ps1 -Verify` |
| `sb maintenance` | home | Opens the maintenance menu: activation, alignment, dossier and data, state and checks, repository lifecycle. | read | CLI only | `scripts/prompts.ps1 -Menu maintenance` |
| `sb mcp` | home | Opens the MCP menu: check the connection, pair an IDE, realign, export the package. | read | CLI only | `scripts/prompts.ps1 -Menu mcp` |
| `sb mcp status` | mcp | Checks which IDE configurations carry the SecondBrain MCP server; -Handshake also runs the stdio handshake. Nothing is written. | verify | CLI only | `scripts/mcp-maintenance.ps1 -Status [-Handshake] [-Target IDE]` |
| `sb mcp pair` | mcp | Previews the MCP configuration for one IDE (-Target) or all; -Apply writes it after saving a backup. | write | CLI only | `scripts/mcp-server.ps1 -Pair [-Target IDE] [-Apply]` |
| `sb mcp realign` | mcp | Finds the IDEs whose MCP configuration is missing and previews the fix; -Apply writes it with a backup. Until aligned, the CLI is used instead of MCP. | write | CLI only | `scripts/mcp-maintenance.ps1 -Realign [-Apply] [-Target IDE]` |
| `sb mcp package` | mcp | Exports the portable MCP package (launcher and modules) to import the connection elsewhere. | write | CLI only | `scripts/mcp-server.ps1 -ExportPackage [-OutDir DIR]` |
| `sb backup` | maintenance | Creates the deterministic compressed backup of the local SecondBrain data; -Customer limits it to one customer dossiers. | write | CLI only | `scripts/backup.ps1 [-Customer NAME]` |
| `sb backup verify` | maintenance | Verifies a backup against its manifest (SHA-256 of every file). A real restore test is a separate maintenance prompt (sb prompt area maintenance). | verify | CLI only | `scripts/backup.ps1 -Verify` |
| `sb sources` | maintenance | Checks the authoritative sources registry locally; remote probes and updates are separate options of the script. | verify | CLI only | `scripts/sources.ps1 -Check` |
| `sb cleanup` | maintenance | Lists the .runtime content by category (preview only). Removal needs a reviewed manifest, -Apply and an explicit authorization. | read | CLI only | `scripts/cleanup.ps1 -ListRuntime` |
| `sb bindings` | maintenance | Previews the migration of the repository bindings to the minimal form; -Apply writes it after backing up the configuration. Repeating it changes nothing. | write | CLI only | `scripts/bindings.ps1 -MigrateBindings [-Apply]` |
| `sb recover` | maintenance | Checks an interrupted dossier transaction from its manifest; -Apply restores it. Preview first. | write | CLI only | `scripts/recover.ps1 -ManifestPath FILE [-Apply]` |
| `sb directives check` | maintenance | Checks that the managed directive blocks of repositories and IDEs match the approved texts, without fixing (same engine as sb check). Changes go through sb directives propose. | verify | CLI only | `scripts/secondbrain.ps1 -Check` |
| `sb directives propose` | maintenance | Prepares a directive revision as a proposal with preview, version and changelog; approval and distribution stay explicit (approve-revision.ps1 -Preview, then sb sync). | per the card | CLI only | `scripts/prompts.ps1 -Compose -Prompt pmt-fd98d7ce -Objective TEXT` |
| `sb prompts check` | maintenance | Validates the prompt catalog and cards and reports drift of the generated indexes. Nothing is written. | verify | CLI only | `scripts/build-prompts.ps1 -Check` |
| `sb onboard` | maintenance | Lean registration of one repository: binding, dossier (brief, context, memory, tracker) and directives; only the managed block is written to the repository. Previews unless -Apply. | write | CLI only | `scripts/onboard.ps1 -Path DIR [-Customer NAME] [-Apply]` |
| `sb offboard` | maintenance | Removes SecondBrain from one repository: binding, managed blocks and pointers go, open tasks are written to TASKS.md, the dossier is saved first. Previews unless -Apply. | write | CLI only | `scripts/offboard.ps1 -RepositoryIdentity ID [-Apply]` |
| `sb resync` | maintenance | Realigns a repository changed outside SecondBrain: prints a plan (safe items and conflicts with the action or prompt to run); -Apply runs the safe sync only. | write | CLI only | `scripts/resync.ps1 -RepositoryIdentity ID [-Apply]` |
| `sb uninstall` | maintenance | Removes what SecondBrain installed (repositories, launchers, IDE blocks, hooks, environment variable) and nothing else; previews by default, data only with -RemoveData and the authorization text. | write | CLI only | `scripts/uninstall.ps1 [-Apply] [-Only STEPS]` |

## Scripts without an `sb` command

Run from the clone root with `pwsh -NoProfile -File scripts/NAME.ps1`. Test scripts (`test-*.ps1`) are in the repository checks, not listed here.

| Script | What it does |
|---|---|
| `access.ps1` | Registers cooperative access to SecondBrain; see docs/reference/operations.md. Status (-Status) is read-only; -Purge removes sessions closed, expired or abandoned for more than 60 minutes. |
| `activity.ps1` | Team activity register (F6): validation, derived index/map and Trace import. |
| `agent-runs.ps1` | Running agents (#627): start, stop, inspect and resume one agent run, with decision handling. |
| `agents.ps1` | Agent CLIs for the task runner and the desktop orchestrator: capability probe, repository-specific directives and one-shot analyses. |
| `approve-revision.ps1` | — |
| `assets.ps1` | — |
| `audit-github.ps1` | — |
| `check-distribution.ps1` | Checks that the SecondBrain Git index contains only public files permitted for distribution. |
| `client-hooks.ps1` | Installs, removes and reports the resources-hook and trace-hook session hooks for Claude Code, Codex and Antigravity. |
| `computer-use.ps1` | Computer use without a person present: capability table per IDE and the opt-in Codex pre-approval (Windows only). |
| `decisions.ps1` | User decision records of the working repository's dossier (decisions.json, asset contracts section 5). |
| `entity.ps1` | — |
| `grant-repositories.ps1` | Issues the standing MCP write grant to every bound repository that has none (owner action; previews by default). |
| `ide-detect.ps1` | Detects the IDEs and AI clients installed on this workstation and lets you choose them and their scope. |
| `ide-observation.ps1` | Delegated IDE/agent verification: instruction package, receipt registration and pruning (#155). |
| `import-tracker.ps1` | — |
| `install-task-launcher.ps1` | Installs the per-repository task launcher (.secondbrain/run-tasks.ps1) in the managed checkouts. |
| `install.ps1` | sb install: one command to onboard a new PC. Chains preflight checks, secondbrain.ps1 -Setup and the enrolment of the repositories. |
| `lint-renames.ps1` | Fails when a live file still cites a renamed script or module. |
| `lint.ps1` | Runs PSScriptAnalyzer on scripts/ and fails on findings not in the tracked baseline. |
| `memory-cycle-hook.ps1` | — |
| `memory-cycle.ps1` | — |
| `migrate-pending-queue.ps1` | Moves the write queue from the old flat layout to one folder per repository. |
| `orchestrate-tasks.ps1` | Runs the autonomous tracker tasks of one checkout one at a time, each in a fresh headless agent process (Claude Code, Codex or Gemini CLI), on a queue branch, with local commits only. |
| `prompt-cards.ps1` | Card lifecycle: add, edit, duplicate, deprecate and retire prompt cards through validated operations. |
| `rename-identity.ps1` | Moves a managed repository to another identity (for example a fork). Previews by default. |
| `resources-hook.ps1` | Session-start bridge: runs resources.ps1 -Sync -IfStale in a detached process; never blocks the session. |
| `resources.ps1` | shared: layout check, control files and indexes, and sync of the authoritative-source registry. |
| `restore-managed.ps1` | Lists backups of files replaced by SecondBrain and restores a file from its backup. |
| `rollback-repo.ps1` | Rolls back a retired or forbidden SecondBrain repository: returns data to the target repository and removes all SecondBrain remnants to protect privacy. |
| `run-ready-tasks.ps1` | Runs ready autonomous tracker tasks one at a time, each in a fresh agent session, for one checkout or for the managed repositories. |
| `runner-gui.ps1` | Opens the desktop runner (Tauri 2 app in app/orchestrator), compiling it first when the binary is missing or out of date. |
| `sandbox-roots.ps1` | — |
| `subagents.ps1` | Subagent definitions (F8): validation, inherited permissions and per-client export. |
| `trace.ps1` | End-of-turn trace for compaction advice (Claude Code Stop hook). |
| `user-prompts.ps1` | User prompts of the Prompts tab (#722): RCTFE prompts of one user, stored outside Git in .runtime/user-prompts/<user>/<id>.json. |
| `work.ps1` | — |
| `workspace.ps1` | Registers and inspects personal workspaces: folders without Git, with a private dossier and an explicit output scope. |

## MCP tools

`get_startup_context`, `get_ready_tasks`, `get_task`, `get_decisions`, `search_knowledge`, `list_prompts`, `get_prompt`, `get_prompt_home`, `get_runner_status`, `list_ides`, `check_publication`, `preview_dossier_write`, `submit_dossier_write`. Details and permissions: [Agents and MCP](../ide-e-mcp.md) and [MCP writes](mcp-writes.md).
