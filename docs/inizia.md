# Getting started

Load one local Git project's context through the CLI, then optionally connect an agent. Use Windows, PowerShell 7.5+ and Git 2.42+. Dossiers and runtime files are ignored by Git and need their own backups.

## Install with one prompt

In a compatible agent (Claude Code, Codex or Antigravity) with a shell tool, send:

~~~text
Install https://github.com/dennidalpos/secondbrain, follow the procedures for my system, tell me where to place it and start the guided setup.
~~~

The agent should follow this procedure and stop for your confirmation at each step marked "ask":

1. Read-only preflight: Windows, PowerShell 7.5+ (`pwsh --version`) and Git 2.42+ (`git --version`). Report anything missing and how to install it; install nothing without asking.
2. Location (ask): propose a short local path outside any product repository and outside cloud-synced folders (for example `C:/Projects/SecondBrain`), because dossiers, runtime files and backups live inside the clone and are ignored by Git. Wait for your answer.
3. Clone (ask) with `git clone https://github.com/dennidalpos/secondbrain.git <chosen path>`; never clone into a non-empty folder.
4. Project choice (ask): list candidate local Git checkouts and let you pick; then run the read-only preview `pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -PreviewOnly -Roots <project> -Select <project>` and show the plan.
5. Guided setup (ask before every write): continue with `sb setup` (prompt SYS17), which walks activation (SYS03), MCP (SYS15) and directives (SYS01) and offers optional features one at a time. Do not use `-Yes` unless you ask for it.

The repository's `AGENTS.md` repeats this entry point, so an agent opening a fresh clone finds the same procedure. Load and write evidence of the real agent session remain separate from file alignment (see [Inspect the result](#inspect-the-result)).

## One command for a new PC

After cloning, `scripts/install.ps1` chains the preflight checks (Windows, Git 2.42+, the project folders), `secondbrain.ps1 -Setup` and the enrolment of each repository. It previews by default and writes nothing; `-Apply` runs Setup with `-Yes -Apply`, which activates the workstation and enrols the repositories.

~~~powershell
pwsh -NoProfile -File scripts/install.ps1 -Roots D:\Projects\my-product
pwsh -NoProfile -File scripts/install.ps1 -Roots D:\Projects\my-product -Apply
~~~

The JSON reports `checks` and one `runs` entry per root. Exit 0 preview or applied, 1 Setup not completed, 2 preflight failed. `-NoRegisterEnvironment` skips the `SECONDBRAIN_HOME` variable. The command adds no setup logic: for IDEs, MCP and optional features continue with `sb setup`. Checked on a synthetic clone; the per-dossier lock on two real PCs is not covered.

## Clone and choose a project

Follow the [README quick start](../README.md#quick-start-load-one-projects-context). It provides the complete clone, read-only preview, explicit activation and Startup commands. The example chooses one existing Git checkout, selects no IDE and uses NoRegisterEnvironment.

Setup creates workstation configuration, the selected dossier and approved repository instructions. It does not copy the example paths into account instructions. A new clone's Check exits with 2 before activation; a valid read-only Setup preview exits with 0 without activating anything.

## Inspect the result

~~~powershell
pwsh -NoProfile -File scripts/secondbrain.ps1 -Check
pwsh -NoProfile -File scripts/knowledge.ps1 -Startup -Profile Slim -NoRecovery -CheckoutPath $project
~~~

Run from the SecondBrain checkout; $project is the path selected in the quick start. In the isolated one-project run, Check exited with 0 and Startup returned profile=Slim and withinBudget=true. Your existing dossier can exceed the budget or have pending conflicts: read the actual issues before proceeding.

Check and knowledge lookups never process pending writes; only `knowledge.ps1 -FlushPending` does. File alignment and actual loading in an agent session are different evidence.

## Setup profiles: solo and studio

One command per profile (add `-Roots`/`-Select` for an explicit selection, `-PreviewOnly` to review first):

~~~powershell
# Solo: one person, local checkout. No shared root, no share ACLs; state stays in the checkout's .runtime.
pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -SetupProfile Solo -Roots $project -Interactive
# Studio: shared authoritative root on a UNC share; workstation state stays local (SECONDBRAIN_STATE_ROOT).
$env:SECONDBRAIN_STATE_ROOT = 'D:/SecondBrainState'
pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -SetupProfile Studio -TeamRoot '\\server\share' -Roots $project -Interactive
~~~

`Solo` rejects `-TeamRoot` and a checkout on a network drive. `Studio` requires `-TeamRoot`, with the same checks as team setup (reachable UNC root, local state outside the share). Access in `Studio` is whatever the share's ACLs grant; SecondBrain sets no ACL in either profile. The JSON result reports `profile`, `sharedRoot`, `acl` and `state`. Without `-SetupProfile` Setup behaves as before. `Studio` on a real share and with distinct accounts is still unqualified (see [shared root](riferimento/shared-brain.md)); the profile commands are checked on synthetic fixtures and, for `Studio`, over loopback UNC when available.

## Optional interactive setup

For interactive confirmation of the selected project, run:

~~~powershell
pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -Interactive -Roots $project -Select $project -NoRegisterEnvironment
~~~

Review the activation and MCP plans. Enter APPLICA only for the displayed scope; any other reply leaves activation unapplied. The documented confirmation/refusal paths can be exercised on synthetic profiles, but this is not a live IDE loading test.

Setup performs Sync for the approved selection. Do not immediately repeat a global Sync merely because an example used it in the past. Use targeted checks and preserve dirty-file conflicts. See [security and side effects](sicurezza.md).

## Git and GitHub updates

SecondBrain asks how to update Git and GitHub for each repository instead of assuming. At task closing a write prompt tells the agent to ask you (commit and push on the main branch is the default proposal; alternatives are a branch with a pull request, or nothing) and then to record the answer in the repository dossier:

~~~powershell
pwsh -NoProfile -File scripts/entity.ps1 -SetGitUpdate -GitMode commit-push-main -GitBranch main -Only <identity>
pwsh -NoProfile -File scripts/entity.ps1 -SetGitUpdate -GitMode commit-push-main -GitBranch main -Only <identity> -Apply -Confirmed
~~~

The first command previews; writing needs both `-Apply` and `-Confirmed`. The stored `gitUpdate` value is a preference for what to propose, not an authorization: the agent still shows what will be committed and runs it only after you confirm in that session, and the runner and delegates never commit or push. `sb setup` lists it as the `git-update` feature.

## Optional MCP pairing

Client scopes differ: Codex and Claude Desktop use user-level pairing; Cursor, VS Code, Claude Code and Antigravity support explicit project scopes in the implementation. See the [target and scope table](ide-e-mcp.md#instruction-and-configuration-targets).

This project-scoped example writes only the selected project's Cursor configuration:

~~~powershell
pwsh -NoProfile -File scripts/mcp-server.ps1 -Pair -Target cursor -Scope project -WorkspacePath $project
pwsh -NoProfile -File scripts/mcp-server.ps1 -Pair -Target cursor -Scope project -WorkspacePath $project -Apply
~~~

Preview first. Apply writes configuration with backup; it does not prove that Cursor is installed, connected or displaying the tools. The example was checked against a synthetic project configuration, not a real client session. Other clients follow their own [MCP setup instructions](riferimento/mcp-setup.md).

## Use an agent and get help

Open a new session in the selected agent and request sb prompt. This is a chat convention from the managed instructions, not an installed shell command. The agent must actually load those instructions. Use the CLI if the client cannot expose MCP.

| Symptom | Next step |
|---|---|
| Check exits with 1 | Read the individual issues; do not treat them as passed checks |
| Startup reports withinBudget=false | Preserve essentials and prepare reviewed dossier maintenance |
| The agent does not understand sb prompt | Check the selected integration and start a new session |
| A tracked instructions file is modified | Preserve the change and review the conflict |
| Automatic memory capture is expected | Read the [current limits](riferimento/memory-cycle.md#known-limits); explicit loading remains available |

Continue with [daily use](uso-quotidiano.md). Use the [bug form](https://github.com/dennidalpos/secondbrain/issues/new/choose) for defects and [SECURITY.md](../SECURITY.md) for private vulnerability reporting.

## Guided first-run setup

On a clean machine, after cloning, ask your agent for `sb setup` (prompt SYS17). It runs `scripts/setup-status.ps1` (read-only: preflight, detected IDEs, and which optional features are enabled, available or unsupported, with the reason and a preview command for each), then walks activation (SYS03), MCP (SYS15) and directives (SYS01) with a confirmation before every write, and finally offers the optional features one at a time. Recommendations come from the current state of the workstation, not from your command history; nothing is enabled without your confirmation. The JSON lists recommended features first, adds a per-feature `summary` and an `exit` object that explains the exit code (1 means recommendations or not activated, not an error).

## Skills for your agents

Ask your agent for `sb skills` (prompt SYS18) in a project. It runs `scripts/skills.ps1 -Analyze` (read-only), proposes only skills that the project's facts justify (detected check commands, layout, changelog, CI), and installs the ones you select for Claude Code, Codex or Antigravity, at project scope (inside the checkout, shareable through Git) or user scope (all your projects). Install previews first; `-Apply` writes `<skill>/SKILL.md` with a backup, and a skill you edited is a conflict that is skipped unless you pass `-Overwrite`. `-Install -Prompt <code>` (for example `-Prompt REP15`) exports a catalog card as the skill `sb-<code>`.

| Agent | Project folder | User folder | Source (checked 2026-11-15) |
|---|---|---|---|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` | [Claude Code skills](https://code.claude.com/docs/en/skills) |
| Codex | `.agents/skills/` | `~/.agents/skills/` | [Codex skills](https://learn.chatgpt.com/docs/build-skills) |
| Antigravity | `.agents/skills/` | `~/.gemini/config/skills/` | [Antigravity skills](https://antigravity.google/docs/skills) |

The folders come from the vendors' documentation, which has changed over time (older Codex and Antigravity paths differ); until a real session lists the skill, SecondBrain reports it as written, not as loaded.
