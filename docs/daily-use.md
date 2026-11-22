# Daily use

Work with your agent as usual. SecondBrain supplies repository context, decisions, tasks and approved instructions. The agent must still respect the permissions of the current session.

## Chat commands

The command words below remain unchanged in every documentation language.

| Type in the agent chat | Purpose |
|---|---|
| `sb prompt` | Show commands, guides and the next step |
| `sb prompt list` | Show the complete prompt list |
| `sb prompt area test` | List one category |
| `sb prompt show QUA05` | Display a prompt card |
| `sb prompt QUA05: check the login flow` | Compose the card with your objective |
| `sb check` | Inspect alignment without changing anything |
| `sb sync` | Sync approved instructions |
| `sb activate` | Discover and activate selected integrations |
| `sb compact` | Preview dossier compaction; applying it requires confirmation |
| `sb reconcile tasks` | Plan the reconciliation of conflicting or invalid queued writes and orphan receipts; `-Apply` for the safe items, `-Decide` for the owner's choices (TRK09) |
| `sb runner` | Run the ready tasks of the current repository from the desktop app or the command line |
| `sb stop` | Stop the agent, save the session in the dossier and resume it from another IDE or account with `sb prompt SES04` (SES03) |
| `sb tasks` | List the open tasks of the repository (`-ReadyOnly` for the runner's) |
| `sb next` | Propose the next steps with the reason for each |
| `sb pending` / `sb pending flush` | List the queued dossier writes / integrate them (conflicts stay queued: `sb reconcile tasks`) |
| `sb queue` / `sb queue status` / `sb queue stop` | Alternative queue for autonomous tasks (`orchestrate-tasks.ps1`), independent of the runner and usable from any managed repository: preview by default, `-Start` runs it detached on a `queue/<date>` branch (local commits, no push), `-Provider claude\|codex\|gemini`; see `docs/orchestrate-tasks.md` |
| `sb runner status` | Show whether the runner is working, stalled, finished or orphaned; `-List` for recent runs, `-Stop` to stop the active one |
| `sb publish check` | Scan the repository for private data and secrets before a push |
| `sb grants` | List the scoped MCP write grants (the owner grants and revokes them in the terminal) |
| `sb projects` | List the repositories bound on this workstation with their task counts |
| `sb status` | Show the setup state: bindings, IDEs and accounts |
| `sb ides` | Check the global instructions of the IDEs, without fixing |
| `sb backup` / `sb backup verify` | Create the local backup / verify it against its manifest |
| `sb sources` | Check the authoritative sources registry |
| `sb cleanup` | List `.runtime` by category (preview); removal needs a reviewed manifest, `-Apply` and an authorization |
| `sb bindings` | Preview the migration of the bindings to the minimal form; `-Apply` writes it |
| `sb recover` | Check an interrupted dossier transaction from its manifest; `-Apply` restores it |
| `sb directives check` | Check the managed directive blocks against the approved texts |
| `sb directives propose` | Prepare a directive revision as a proposal; approval and distribution stay explicit |
| `sb prompts check` | Validate the prompt catalog and cards and report drift of the generated indexes |

See the [per-repository workflow](product-flow.md) for the order of operations.

### Mechanical compaction (no model)

`knowledge.ps1 -Compact -Mechanical` moves the oldest dated `##` sections of `context.md` and `memory.md` to the history tier (`<!-- sb:tier=history -->`) until the startup context (package plus directive text) is at 70% of the budget (`-TargetPercent`). It rewrites nothing and deletes nothing: the sections stay in the files, are left out of the startup package, and remain available through `-Section` and `-Search`. Originals are archived by hash in `history/compaction/`, and `memory.agent.md` and `index.md` are regenerated in the same transaction.

- Eligible: sections whose newest `yyyy-MM-dd` date is older than `-OlderThanDays` (default 30). Never touched: undated sections, the required context sections, sections already in history, sections with an active `sb:decision` marker.
- Without `-Apply` it only previews; `-TriggerPercent N` makes it act only when the context is at N% of the budget or more.
- It runs by itself when a task is closed with `knowledge.ps1 -UpdateTaskId <id> -Status done`, at 80% of the budget. Opt out with `-NoAutoCompact` or `SECONDBRAIN_AUTO_COMPACT=0`. A failure is reported on stderr and never changes the exit code of the close.
- Undo: restore the archived original from `history/compaction/<hash>/`, or remove the marker line.

## Folders and the dossier

| Folder | Use |
|---|---|
| `repos/` | One folder per managed repository (specs, material, data, context, memory, tracker) |
| `workstation/` | Continuing responsibilities that are not a repository (governance, workstation, directives) |
| `shared/` | Reference material shared by all repositories |

There are no archive folders: an inactive entity keeps its place and has a status other than `active`; do not reactivate it implicitly.

A repository dossier contains `index.md`, `context.md`, `memory.md`, `repository.json` and its declared tracker. Resolve it by repository identity, not the folder name. A declared dossier tracker is authoritative; a missing or invalid tracker is an error, not permission to use another file.

Durable decisions use `Decision: … — Reason: …` in memory (the Italian `Decisione: … — Motivo: …` form in older entries is still read). Keep only verified, useful changes in context and memory. Read the essential startup package first, then request relevant task details and historical evidence. Slim defaults to 25,000 characters for the first load; characters are not tokens. See [loading and maintenance](reference/runtime-maintenance.md).

## One entry point: `sb`

`scripts/sb.ps1` runs every `sb` command from a terminal; the existing scripts stay the implementation and extra arguments are passed through.

~~~powershell
pwsh -NoProfile -File scripts/sb.ps1 help                 # every command with a one-line description
pwsh -NoProfile -File scripts/sb.ps1 check                # same as scripts/secondbrain.ps1 -Check
pwsh -NoProfile -File scripts/sb.ps1 prompt show KEY      # same as scripts/prompts.ps1 -Show -Prompt KEY
pwsh -NoProfile -File scripts/sb.ps1 runner -RepositoryPath <checkout>
~~~

An unknown command is refused with a pointer to `sb help`.

## Onboard and offboard one repository

Both preview by default and change nothing until `-Apply`.

~~~powershell
pwsh -NoProfile -File scripts/sb.ps1 onboard -Path <checkout> [-Customer <name>] [-Apply]
pwsh -NoProfile -File scripts/sb.ps1 offboard -RepositoryIdentity <identity> [-Forbid] [-Apply]
~~~

- **Onboard** records the repository in the local allowlist and activates it: binding, dossier (brief, context, memory, tracker) and directives. The only thing written to the repository is the managed block (and the managed pointer blocks).
- **Resync** realigns a repository that was edited outside SecondBrain or not opened for a long time: `sb resync -RepositoryIdentity <identity>` prints a plan (exit code 2 when a decision is needed). Safe items (out-of-date managed blocks and generated views) are realigned with `-Apply`; every conflict names the action to take in the repository or the prompt to run. Nothing is written without `-Apply`.
- **Uninstall** (`sb uninstall`) removes only what SecondBrain installed. The preview lists every item to remove and every item that stays; `-Apply` runs the steps `repositories` (offboard of every binding), `launchers` (only when identical to a template), `ide-blocks` (managed blocks by their markers, other text kept, verified backups), `mcp` (the secondbrain server entry removed from the Claude Code, Codex and other client MCP files after a backup; other servers stay), `hooks` and `environment`. Pick steps with `-Only ide-blocks,launchers`. Dossiers and the contents of `shared/` are removed only with `-Only data,shared -RemoveData -Authorization "delete dossiers"`. `.runtime` goes last and only with `-Only runtime -RemoveRuntime -RuntimeAuthorization "delete runtime and backups"`: the backups this command wrote are deleted with it. The checkout itself is never removed. A scan for remaining markers and MCP entries closes the report (exit code 2 if any remains).
- **Offboard** removes the binding, the managed blocks and the pointers, writes the open tasks to `TASKS.md` in the repository and saves the whole dossier in the backup folder before removing it. Afterwards `git status` equals a fresh clone plus `TASKS.md`.

## CLI lookups

Run these from the SecondBrain checkout, passing the product checkout explicitly:

~~~powershell
pwsh -NoProfile -File scripts/knowledge.ps1 -Startup -NoRecovery -CheckoutPath C:/Projects/MyProduct
pwsh -NoProfile -File scripts/knowledge.ps1 -Tasks -ReadyOnly -NoRecovery -CheckoutPath C:/Projects/MyProduct
pwsh -NoProfile -File scripts/knowledge.ps1 -Task TASK-ID -NoRecovery -CheckoutPath C:/Projects/MyProduct
~~~

The global task view requires `-All` and is paginated. Task edits belong to the repository being worked on. An audit that only proposes tracker changes must leave the tracker untouched.

## Before publication

~~~powershell
pwsh -NoProfile -File scripts/publication.ps1 -RepositoryPath C:/Projects/MyProduct
~~~

The gate scans working tree, index and relevant history, subject to its reported coverage. Review findings, binary limitations and any accepted fingerprints. A clean pattern scan is not proof that every secret or private detail has been found. Commit and push each require the user's authorization.

## Running tracker tasks

To work through the ready autonomous tasks, one fresh agent session per task and one repository at a time, use `scripts/run-ready-tasks.ps1`. It previews by default and prints progress on the console while it runs. `-Run` also needs `-Model` and `-Effort`, or `-UseCliDefault`; without a choice it exits 2 and lists the options the installed CLI exposes. See [running tracker tasks](reference/operations.md#running-tracker-tasks-in-fresh-sessions) for options, safety limits and results.

## Versions and closure

A documentation correction does not automatically require a new version. Propose a version only when justified; change it and the changelog only after acceptance.

At an authorized task closure, verify acceptance criteria, preserve task IDs and history, update the permitted dossier records and run Sync and Check. Repository memory collection is enabled only explicitly and requires a verified permission policy for the current turn.

## Terms

A dossier is a repository's knowledge folder; a tracker stores tasks; a managed block is the delimited text Sync maintains; MCP connects the client to the local server. See [trackers](reference/trackers.md), [PARA](reference/tree.md) and [operations](reference/operations.md).
