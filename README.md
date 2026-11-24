# SecondBrain for Coding Agents

![Version 4.0.1](https://img.shields.io/badge/version-4.0.1-blue) ![Windows](https://img.shields.io/badge/Windows-0078D6) ![PowerShell 7.5+](https://img.shields.io/badge/PowerShell-7.5%2B-5391FE)

**Project context, decisions, tasks and shared rules for coding agents on Windows.**

SecondBrain stores private project dossiers outside the public Git content. An agent loads the relevant dossier through PowerShell or the optional local MCP server. Approved instruction blocks can be distributed to selected repositories and agent configurations.

Use it when you want Claude Code, Codex or Antigravity to work from the same project notes and rules. A Git clone contains the scripts and public guides; it does not contain your ignored dossiers or their backups.

~~~mermaid
flowchart LR
    U[You] --> A[Coding agent]
    A --> L[Explicit context lookup]
    L --> D[Selected project dossier]
    D --> C[Context, decisions and tasks]
    C --> A
    R[Approved rules] --> P[Selected repository instructions]
~~~

## Who it is for, isolation and when not to use it

Two profiles are supported:

- **Single user:** one person on one Windows workstation keeps decisions, tasks and notes for each project once, and every coding agent reads the same source.
  Setup: `scripts/secondbrain.ps1 -Setup -SetupProfile Solo -Roots <folder> -Interactive` (no shared root, no ACLs).
- **Design and development studio:** each client or internal project has its own dossier, kept apart from the client's repository. The shared-root mode for several people is documented but not yet qualified on a real network share or with distinct accounts; treat it as a trial.
  Setup: `scripts/secondbrain.ps1 -Setup -SetupProfile Studio -TeamRoot <UNC> -Roots <folder> -Interactive` (local state in `SECONDBRAIN_STATE_ROOT`).

Isolation is per repository: a dossier is read and written only for its own repository, and cross-project reads are refused unless the workstation configuration explicitly allows them. Dossiers are private local data and are never part of the public Git content.

SecondBrain also holds a registry of authoritative sources (laws, standards, product documentation) with a verification state per source ([guide](docs/reference/authoritative-sources.md)). The registry, its tooling and the Markdown transcripts of reusable sources are in the repository, each under its own terms ([CREDITS](CREDITS.md#4-third-party-texts-in-the-source-registry)); the downloaded originals stay local and are not distributed by Git.

Alternatives are often enough. Prefer a plain `AGENTS.md` or `CLAUDE.md` file for a single small repository whose notes fit in one page. Do not use SecondBrain if you are not on Windows, if you cannot run PowerShell 7.5+, or if you need context captured automatically from every chat: loading is explicit and native capture is partial (see the limits below).

## Quick start: load one project's context

You need Windows, PowerShell 7.5+ and Git 2.42+. Choose an existing local Git repository for MyProject. Read [what Setup changes](docs/security.md) first.

Run in PowerShell; replace the two example paths:

~~~powershell
$brain = 'C:/Projects/SecondBrain'
$project = 'C:/Projects/MyProject'
git clone https://github.com/dennidalpos/secondbrain.git $brain
Set-Location $brain
pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -PreviewOnly -Roots $project -Select $project
~~~

The preview discovers the selected checkout without activating it. Review the plan. To authorize activation for that repository:

~~~powershell
pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -Roots $project -Select $project -Yes -Apply -NoRegisterEnvironment
~~~

Setup creates the dossier and workstation configuration and synchronizes approved repository instructions. This example selects no IDE and leaves the user-level environment variable unchanged. Existing conflicting instructions are preserved and reported.

Load the dossier and open the next-task prompt:

~~~powershell
pwsh -NoProfile -File scripts/knowledge.ps1 -Startup -Profile Slim -NoRecovery -CheckoutPath $project
pwsh -NoProfile -File scripts/prompts.ps1 -Show -Prompt TRK02
~~~

Check the returned repository identity, profile and withinBudget value. A budget failure is a result to resolve, not a successful context load. The sequence was exercised again on 2026-11-22 from a fresh clone with one synthetic Git repository: preview, activation, Startup (`withinBudget: true`) and an empty ready-task list; no agent login was needed. If `config/local/allowlist.json` exists, the preview fails with "Repository not selectable (0 matches)" for any repository not listed there (see the limits below).

For interactive selection, team setup and a new agent session, continue with [Getting started](docs/getting-started.md).

**Install with one prompt.** In a compatible agent, send: "Install https://github.com/dennidalpos/secondbrain, follow the procedures for my system, tell me where to place it and start the guided setup." The agent checks the prerequisites, asks where to place the clone, previews the setup and asks before every write ([procedure](docs/getting-started.md#install-with-one-prompt)).

## Common tasks

Run from the SecondBrain checkout. Keep $project set to the selected project path.

~~~powershell
pwsh -NoProfile -File scripts/knowledge.ps1 -Tasks -ReadyOnly -NoRecovery -CheckoutPath $project
pwsh -NoProfile -File scripts/secondbrain.ps1 -Check
~~~

- **Read project knowledge:** use Startup, task lookup or search; [daily use](docs/daily-use.md) explains the CLI and chat conventions.
- **Change a task or memory:** review the operation and its approval requirements. The [MCP write guide](docs/reference/mcp-writes.md) covers the local receipt for each submitted operation.
- **Run the ready tasks:** `scripts/run-ready-tasks.ps1` runs them one at a time with Claude Code, Codex or Gemini CLI; the [desktop orchestrator](docs/orchestratore.md) picks the repository, the directives, the model and the effort level. Open it without an IDE with `pwsh -NoProfile -File start.ps1` from the clone root. To work through the ready tasks unattended, `scripts/orchestrate-tasks.ps1` previews the selection by default; `-Run` works on a `queue/<date>` branch, commits locally and never pushes ([guide](docs/orchestrate-tasks.md)).
- **Use prompt cards:** 130 English cards cover development, review, documentation and maintenance. 15 presets chain cards for a bigger job; `scripts/prompts.ps1 -Preset wf-NAME -Objective TEXT` composes a whole preset as one document. [Prompt guide](docs/prompt.md).
- **Back up private knowledge:** preserve the dossier and recovery records separately from Git. [Backup and recovery](docs/security.md).

A new dossier has no recorded tasks, so an empty ready-task list is expected.

Check and knowledge reads never write: queued dossier writes are integrated only by an explicit `knowledge.ps1 -FlushPending`. NoRecovery additionally refuses any write in the same command.

## Configuration and agent connections

Setup can select repositories and supported IDE integrations interactively. MCP is optional: the CLI exposes the same project knowledge.

| Integration | What is implemented | What to verify separately |
|---|---|---|
| Repository instructions | A newly activated repository gets a managed AGENTS.md block and CLAUDE.md/GEMINI.md pointers, created when absent, with text outside the managed blocks kept; `-RepositoryFiles` chooses the files (`none` opts out, a repeated activation keeps the earlier choice; repositories bound before 2.8.0 keep their managed files); guided `-ResolveBlock` for hand-edited blocks | Loading in a new agent session |
| MCP configuration | Client-specific preview and pairing | Actual tool exposure, profile and popup behavior |
| MCP server | Thirteen tools, including runner status, user decisions and reviewed dossier-write preview and submission | Client consent and the local receipt for each write |
| Memory collection | Guided envelopes, per-turn Permit CLI and a native bridge | Current implementation limits and live qualification |

See [Agents and MCP](docs/ide-e-mcp.md) for client scopes. An updated file or a successful synthetic handshake does not prove that a client loaded the configuration.

SECONDBRAIN_HOME can identify the checkout on your workstation; scripts can also bootstrap from their own checkout. SECONDBRAIN_STATE_ROOT selects local workstation state, including when dossiers use an explicitly configured shared root. Keep machine paths and receipts out of public repositories. [Configuration reference](docs/reference/portable-brain.md).

Each repository has a dossier under `repos/`. Startup loads the essential dossier content first. [Architecture](docs/reference/architecture.md) describes the data boundaries and modules.

## Limits of the current version

- Windows only; PowerShell and Git are required.
- Setup discovery skips folders named `AppData`, `Windows`, `Program Files`, `node_modules` and `.venv`; a local `config/local/allowlist.json`, when present, limits it to the listed repositories.
- Context loading must be requested through the CLI, MCP or an agent workflow. Setup does not make every client remember or capture every chat automatically.
- Native memory capture remains partial. The native bridge accepts only a native Stop event and binds Permit Apply to the reviewed preview hash, tested on synthetic fixtures only. Use the guided workflow and read the [known memory-cycle limits](docs/reference/memory-cycle.md#known-limits) before enabling a native bridge.
- Synthetic fixtures do not qualify real IDE sessions, account permissions, crashes or multiple physical hosts on SMB.
- Ignored dossier files are private local/shared data, not a backup supplied by Git.

## Help and contributor checks

Start with [Getting started](docs/getting-started.md), [daily use](docs/daily-use.md) or the [technical reference](docs/reference/operations.md).

Report defects through the [bug form](https://github.com/dennidalpos/secondbrain/issues/new/choose). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Contributions follow [CONTRIBUTING.md](CONTRIBUTING.md).

For documentation and code changes, run Quick and the checks relevant to the change:

~~~powershell
pwsh -NoProfile -File scripts/test-secondbrain.ps1 -Quick
pwsh -NoProfile -File scripts/build-prompts.ps1 -Check
pwsh -NoProfile -File scripts/check-distribution.ps1
~~~

[Verification levels](docs/reference/runtime-maintenance.md#verification-levels) distinguish Quick, Fast, Full and live qualification. [RSK07](docs/reference/operations.md#publication) separately checks text and Git inventory before publication. Passing one level does not imply the others passed.

MIT License. [Sources and acknowledgements](CREDITS.md).
