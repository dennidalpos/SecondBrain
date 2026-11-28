# SecondBrain command reference

Each row shows a command or parameter, a short description and an example. Indented rows belong to the command above. Replace sample paths, repository names, URLs and task IDs before running an example. See the [user guide](cli/README.md) for workflows.

## Help and navigation

| Command or parameter | Description | Example |
|---|---|---|
| `sb start` | Show the start screen: status and the next step | `sb start` |
| ↳ `<AREA>` | Command area to browse | `sb start work` |
| ↳ `<COMMAND...>` | Command and optional subcommands within the area | `sb start work task add` |
| `sb commands` | List every command with its parameters | `sb commands` |
| `sb guide` | Explain commands and workflows | `sb guide onboarding` |
| ↳ `<TOPIC>` | overview, commands, onboarding, tasks, chat, rules, skills, run, check or mcp (default: overview) | `sb guide chat` |
| `sb` | Open the start screen | `sb` |
| `sb help` | Show help for a command path | `sb help task add` |
| ↳ `[COMMAND...]` | Command and optional subcommand | `sb help task add` |

Start areas are `setup`, `work`, `rules`, `publish` and `help`. Menus are read-only and work before the data folder is initialized.

### Common options

| Command or parameter | Description | Example |
|---|---|---|
| ↳ `--home <PATH>` | Use a different data folder (default: SB_HOME, then the user data folder) | `sb --home ./scratch-data init` |
| ↳ `-h, --help` | Show command help | `sb task add --help` |
| ↳ `-V, --version` | Show the installed version | `sb --version` |

## Setup

| Command or parameter | Description | Example |
|---|---|---|
| `sb init` | Create the SecondBrain folder | `sb init` |
| `sb add` | Add the current repository and link its agent files | `sb add` |
| ↳ `<PATH>` | Repository folder (default: the current folder) | `sb add ./sample-project` |
| ↳ `--files <FILES>` | Files to link: agents, claude, gemini (default: agents,claude) | `sb add --files agents,gemini` |
| ↳ `--no-files` | Do not write any file in the repository | `sb add --no-files` |
| `sb unlink` | Remove the SecondBrain block from a repository | `sb unlink` |
| ↳ `<PATH>` | Repository folder (default: the current folder) | `sb unlink ./sample-project` |
| `sb relink` | Point a local repository's dossier at its new folder | `sb relink sample-project` |
| ↳ `<REPO>` | Identity or name of the dossier, as listed by `sb repos` (required) | `sb relink sample-project` |
| ↳ `<PATH>` | The checkout's new folder (default: the current folder) | `sb relink sample-project ./sample-project` |
| `sb repos` | List the repositories | `sb repos` |
| `sb doctor` | Find and repair drifted folders, links and MCP registrations | `sb doctor` |
| ↳ `--fix` | Repair what can be repaired without a decision | `sb doctor --fix` |

Run `sb init` once per machine. After linking a checkout, use `sb guide onboarding` to inspect it and save initial context. `sb doctor` exits with code 2 when findings remain.

## Context and work

| Command or parameter | Description | Example |
|---|---|---|
| `sb context` | Print the repository context (--set replaces it) | `sb context` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `sb context --repo sample-project` |
| ↳ `--set` | Replace the context with the text read from standard input | `echo "The API starts in src/main.rs" \| sb context --set` |
| ↳ `--if-empty` | Save initial context only if the dossier still has none (requires --set) | `echo "The API starts in src/main.rs" \| sb context --set --if-empty` |
| ↳ `--budget <TOKENS>` | Keep the output within about this many tokens (a large state loses whole sections) | `sb context --budget 500` |
| ↳ `--compact` | Shorthand for a small budget (1500 tokens unless --budget is given) | `sb context --compact` |
| `sb decide` | Record a durable decision | `sb decide "Use SQLite for search because it works offline"` |
| ↳ `<TEXT>` | Decision and its reason, on one line (required) | `sb decide "Use SQLite for search because it works offline"` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `sb decide "Use SQLite for search because it works offline" --repo sample-project` |
| `sb search` | Search context, decisions, tasks and sources | `sb search "login redirect"` |
| ↳ `<QUERY>` | Words to search for in the dossiers (required) | `sb search "login redirect"` |
| ↳ `--repo <REPO>` | Limit the search to one repository (default: all) | `sb search "login redirect" --repo sample-project` |
| `sb run` | Work through the open tasks unattended, one agent per task | `sb run --dry-run` |
| ↳ `--agent <AGENT>` | claude, codex or gemini (asked when omitted) | `sb run --agent codex --model gpt-6.2-sol --limit 1` |
| ↳ `--agent-cmd <AGENT_CMD>` | Any other agent: a command that reads the prompt on standard input | `sb run --agent-cmd ./my-agent --limit 1` |
| ↳ `--task <TASK>` | Run only this task | `sb run --task 7 --agent codex --model gpt-6.2-sol` |
| ↳ `--limit <LIMIT>` | Run at most this many tasks | `sb run --limit 3 --agent codex --model gpt-6.2-sol` |
| ↳ `--all` | Run every ready task | `sb run --all --agent codex --model gpt-6.2-sol` |
| ↳ `--model <MODEL>` | Model for a known agent (asked for in a terminal, required otherwise) | `sb run --model gpt-6.2-sol --agent codex --limit 1` |
| ↳ `--effort <EFFORT>` | Effort level for Claude or Codex: low, medium, high, xhigh or max | `sb run --effort high --agent codex --model gpt-6.2-sol --limit 1` |
| ↳ `--timeout <TIMEOUT>` | Minutes before an agent is stopped (default: 30) | `sb run --timeout 45 --agent codex --model gpt-6.2-sol --limit 1` |
| ↳ `--allow-cmd <ALLOW_CMD>` | Program Claude Code or Gemini CLI may run without asking (Gemini 0.68+ through a per-run policy file in the data folder, older builds through --allowed-tools), such as cargo (repeatable; the programs in each task's acceptance command and Commands handoff are always allowed) | `sb run --allow-cmd cargo --agent claude --model sonnet --limit 1` |
| ↳ `--dry-run` | List the tasks that would run, then stop | `sb run --dry-run` |

Without a terminal, a built-in agent needs a model and one of `--task`, `--limit` or `--all`. Custom agent commands manage their own model. [Unattended runs](cli/README.md#unattended-runs)

### Sources

| Command or parameter | Description | Example |
|---|---|---|
| `sb kb` | Sources: extracted text of documents, notes and media kept per repository (PARA) | `sb kb list` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `sb kb --repo sample-project list` |
| `sb kb add` | Store extracted text as a source (reads standard input unless --text-file is given) | `echo "# Extracted text" | sb kb add "Supplier contract 2026"` |
| ↳ `<TITLE>` | Short source title (required) | `echo "# Extracted text" | sb kb add "Supplier contract 2026"` |
| ↳ `--text-file <FILE>` | Read the extracted text from this file instead of standard input | `sb kb add "Supplier contract 2026" --text-file ./extract.md` |
| ↳ `--kind <KIND>` | file, web, note, chat, connector or media (default: file with --original, else note) | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --kind file` |
| ↳ `--origin <ORIGIN>` | Where the text came from (URL, connector item or path); the same origin makes a new revision | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --origin https://example.invalid/contract` |
| ↳ `--original <FILE>` | Copy this original file into the folder that only you read; sb never opens it afterwards | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --original ./contract.pdf` |
| ↳ `--para <PARA>` | project, area, resource or archive (default: project with --task, else resource) | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --para archive` |
| ↳ `--tag <TAG>` | Tags, comma separated | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --tag contract,2026` |
| ↳ `--task <TASK>` | Task this source belongs to | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --task 7` |
| ↳ `--summary <SUMMARY>` | Three to five lines that say what the source holds | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --summary "Signed supplier contract; renewal due in March"` |
| ↳ `--allow-sensitive` | Keep the text although it looks like it holds secrets or personal data | `echo "# Extracted text" | sb kb add "Supplier contract 2026" --allow-sensitive` |
| `sb kb list` | List the current sources | `sb kb list` |
| ↳ `--para <PARA>` | Only this PARA group: project, area, resource or archive | `sb kb list --para archive` |
| ↳ `--tag <TAG>` | Only sources with this tag | `sb kb list --tag contract,2026` |
| ↳ `--task <TASK>` | Only sources of this task | `sb kb list --task 7` |
| ↳ `--json` | Print sources as machine-readable JSON | `sb kb list --json` |
| `sb kb show` | Show one source with its summary and chunks | `sb kb show 7` |
| ↳ `<ID>` | Source number (required) | `sb kb show 7` |
| ↳ `--chunk <CHUNK>` | Show only this chunk (1-based) | `sb kb show 7 --chunk 2` |
| ↳ `--budget <TOKENS>` | Keep the output within about this many tokens | `sb kb show 7 --budget 500` |
| `sb kb search` | Search the sources (ranked, with a snippet); archived sources rank lower | `sb kb search "login redirect"` |
| ↳ `<QUERY>` | Words to search for (required) | `sb kb search "login redirect"` |
| ↳ `--para <PARA>` | Only this PARA group | `sb kb search "login redirect" --para archive` |
| ↳ `--limit <LIMIT>` | Show at most this many sources (default: 20) | `sb kb search "login redirect" --limit 3` |
| `sb kb move` | Move a source to another PARA group | `sb kb move 7 archive` |
| ↳ `<ID>` | Source number (required) | `sb kb move 7 archive` |
| ↳ `<PARA>` | project, area, resource or archive (required) | `sb kb move 7 archive` |
| `sb kb tag` | Add or remove tags on a source | `sb kb tag 7 --add contract,2026` |
| ↳ `<ID>` | Source number (required) | `sb kb tag 7 --add contract,2026` |
| ↳ `--add <ADD>` | Tags to add, comma separated | `sb kb tag 7 --add contract,2026` |
| ↳ `--remove <REMOVE>` | Tags to remove, comma separated | `sb kb tag 7 --remove contract,2026` |
| `sb kb rm` | Delete a source and its chunks (the original file is never deleted) | `sb kb rm 7` |
| ↳ `<ID>` | Source number (required) | `sb kb rm 7` |
| `sb kb stats` | Counts per PARA group, size, and originals without a source | `sb kb stats` |
| `sb kb compact` | Drop superseded revisions and duplicate chunks, strip repeated headers and blobs, then vacuum | `sb kb compact --dry-run` |
| ↳ `--dry-run` | Show what would be removed without changing anything | `sb kb compact --dry-run` |
| `sb kb export` | Write one Markdown file per source (with front matter) into an empty folder outside Git | `sb kb export --out ../sample-sources` |

The caller extracts the text (an agent in a desktop app, a plugin or connector, or a person); sb stores it as chunks in `kb.db` inside the repository's dossier, searchable with SQLite FTS5. `--original` copies the file once into `originals/<dossier>/` in the data folder (or `SB_ORIGINALS`, which must be outside any Git repository); sb never opens it again, and neither `kb.db` nor `originals/` is synchronized by `sb sync`. A text that looks like a secret or personal data is refused unless `--allow-sensitive` is given. Read `sb guide sources` for the workflow.

### Tasks

| Command or parameter | Description | Example |
|---|---|---|
| `sb task` | Manage tasks, claims and unattended handoffs | `sb task list` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task --repo sample-project list` |
| `sb task add` | Create a task | `sb task add "Fix the login redirect"` |
| ↳ `<TITLE>` | Short task title (required) | `sb task add "Fix the login redirect"` |
| ↳ `--body <BODY>` | Task scope, inputs and acceptance criteria | `sb task add "Fix the login redirect" --body "Preserve the requested return URL"` |
| ↳ `-p, --priority <PRIORITY>` | 1 (highest) to 4 | `sb task add "Fix the login redirect" --priority 2` |
| ↳ `--needs-user` | A person must act or decide | `sb task add "Fix the login redirect" --needs-user` |
| ↳ `--blocked-by <IDS>` | Ids of tasks that must be done first (comma separated) | `sb task add "Fix the login redirect" --blocked-by 3,5` |
| ↳ `--accept <COMMAND>` | A command that must exit 0 before an unattended run marks the task done | `sb task add "Fix the login redirect" --accept "cargo test"` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task add "Fix the login redirect" --repo sample-project` |
| `sb task list` | List open tasks (--all includes done ones) | `sb task list` |
| ↳ `--all` | Include completed tasks | `sb task list --all` |
| ↳ `--json` | Print tasks as machine-readable JSON | `sb task list --json` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task list --repo sample-project` |
| `sb task ready` | List the tasks that can start now: todo, unblocked, free, not waiting on a person | `sb task ready` |
| ↳ `--json` | Print ready tasks as machine-readable JSON | `sb task ready --json` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task ready --repo sample-project` |
| `sb task claim` | Take a ready task for a while (the lease runs out after --minutes) | `sb task claim 7 --by docs-agent` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task claim 7 --by docs-agent` |
| ↳ `--by <BY>` | Who takes it (an agent or a person) (required) | `sb task claim 7 --by docs-agent` |
| ↳ `--minutes <MINUTES>` | Minutes before the task claim expires (default: 30) | `sb task claim 7 --by docs-agent --minutes 15` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task claim 7 --by docs-agent --repo sample-project` |
| `sb task release` | Give a claimed task back | `sb task release 7` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task release 7` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task release 7 --repo sample-project` |
| `sb task show` | Show one task | `sb task show 7` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task show 7` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task show 7 --repo sample-project` |
| `sb task done` | Mark a task done | `sb task done 7` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task done 7` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task done 7 --repo sample-project` |
| `sb task archive` | Move old done tasks and old decisions to the archive (still searchable) | `sb task archive --older-than 90` |
| ↳ `--older-than <DAYS>` | Archive done tasks and decisions last touched more than this many days ago (required) | `sb task archive --older-than 90` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task archive --repo sample-project --older-than 90` |
| `sb prepare` | List the tasks waiting for input and how an agent interviews the owner to prepare them | `sb prepare` |
| ↳ `<ID>` | Show one task instead of the whole queue | `sb prepare 7` |
| ↳ `--json` | Print the queue as JSON | `sb prepare --json` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb prepare --repo sample-project` |
| `sb task prepare` | Interview the owner and prepare a task for unattended work | `sb task prepare 7` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task prepare 7` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task prepare 7 --repo sample-project` |
| `sb task set` | Change a task | `sb task set 7 --status blocked` |
| ↳ `<ID>` | Task number in the repository (required) | `sb task set 7 --status blocked` |
| ↳ `--status <STATUS>` | todo, doing, blocked or done | `sb task set 7 --status blocked` |
| ↳ `--title <TITLE>` | Replace the task title | `sb task set 7 --title "Fix the login redirect"` |
| ↳ `-p, --priority <PRIORITY>` | New priority from 1 (highest) to 4 | `sb task set 7 --priority 2` |
| ↳ `--needs-user <NEEDS_USER>` | Whether a person must act or decide (true or false) | `sb task set 7 --needs-user true` |
| ↳ `--body <BODY>` | Replace the task description and acceptance criteria | `sb task set 7 --body "Preserve the requested return URL"` |
| ↳ `--blocked-by <IDS>` | Ids of tasks that must be done first (comma separated; empty clears) | `sb task set 7 --blocked-by 3,5` |
| ↳ `--accept <COMMAND>` | The acceptance command (empty clears) | `sb task set 7 --accept "cargo test"` |
| ↳ `--repo <REPO>` | Repository (identity, its last part, or a folder; default: the current one) | `sb task set 7 --repo sample-project --status blocked` |

Use `sb prepare` to list the tasks waiting for input; an agent then interviews you with its structured question tool (`sb guide prepare`) and saves each answer set with the MCP tool `prepare_task`. Use `sb task prepare 7` in a terminal to record scope, acceptance, checks, inputs and decisions. Finish the interview with `ready` to clear the human-input flag, `hold` to keep it, or `cancel` to discard the interview. The interview does not start an agent. On `task set`, pass an empty value to clear dependencies or the acceptance command. To work through eligible tasks in chat, ask the agent to load the `chat` guide.

## Rules and skills

| Command or parameter | Description | Example |
|---|---|---|
| `sb rules` | General and repository rules: show, set, sync | `sb rules show` |
| `sb rules show` | Print the general rules and the repository's rules | `sb rules show` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `sb rules show --repo sample-project` |
| `sb rules set` | Replace the repository's rules (or the general ones with --general) from standard input | `echo "Run cargo test before committing." \| sb rules set` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `echo "Run cargo test before committing." \| sb rules set --repo sample-project` |
| ↳ `--general` | Replace the general rules (rules.md) instead | `echo "Run cargo test before committing." \| sb rules set --general` |
| `sb rules sync` | Refresh managed instructions in linked repositories or explicit agent files | `sb rules sync` |
| ↳ `--agent-file <FILE>` | Global agent instructions file (repeat to select more files) | `sb rules sync --agent-file ./agent-profile/AGENTS.md` |
| ↳ `--check` | Check the selected files without writing (exit 2 if any differ) | `sb rules sync --check --agent-file ./agent-profile/AGENTS.md` |
| `sb skill` | Skills kept in SecondBrain: list, show, add, remove | `sb skill list` |
| `sb skill list` | List the skills | `sb skill list` |
| `sb skill show` | Print a skill | `sb skill show review-checklist` |
| ↳ `<NAME>` | Skill name (required) | `sb skill show review-checklist` |
| `sb skill add` | Store or replace a skill (text from --file or standard input) | `sb skill add review-checklist --file ./SKILL.md` |
| ↳ `<NAME>` | Skill name (required) | `sb skill add review-checklist --file ./SKILL.md` |
| ↳ `--file <FILE>` | Source Markdown file (default: read standard input) | `sb skill add review-checklist --file ./SKILL.md` |
| `sb skill remove` | Remove a skill | `sb skill remove review-checklist` |
| ↳ `<NAME>` | Skill name (required) | `sb skill remove review-checklist` |

## Publication and data transfer

| Command or parameter | Description | Example |
|---|---|---|
| `sb check` | Scan a push for secrets, personal data and dossier text | `sb check` |
| ↳ `<PATH>` | Repository folder (default: the current folder) | `sb check ./sample-project` |
| ↳ `--history` | Scan every commit of every branch, not only the unpushed ones | `sb check --history` |
| ↳ `--json` | Print findings as machine-readable JSON | `sb check --json` |
| ↳ `--install-hook` | Install a Git pre-push hook that runs `sb check` | `sb check --install-hook` |
| ↳ `--uninstall-hook` | Remove the pre-push hook installed by sb | `sb check --uninstall-hook` |
| `sb migrate` | Import the open tasks exported from SecondBrain 4 | `sb migrate ./secondbrain-v4.json` |
| ↳ `<FILE>` | Path to the export from SecondBrain 4 (required) | `sb migrate ./secondbrain-v4.json` |
| ↳ `--link` | Also link AGENTS.md and CLAUDE.md in each recorded checkout | `sb migrate ./secondbrain-v4.json --link` |
| `sb import` | Add a repository's AGENTS.md, CLAUDE.md and Cursor rules to its rules | `sb import` |
| ↳ `<PATH>` | Repository folder (default: the current folder) | `sb import ./sample-project` |
| ↳ `--pack <FILE>` | Import a repository pack (.sbkb) written by `sb export --format sqlite` | `sb import --pack ./team.sbkb` |
| ↳ `--repo <REPO>` | With `--pack`: the repository to import into (must match the pack's identity) | `sb import --repo sample-project --pack ./team.sbkb` |
| ↳ `--merge` | With `--pack`: add what is missing and keep the local text (default) | `sb import --merge --pack ./team.sbkb` |
| ↳ `--replace` | With `--pack`: make the dossier equal to the pack, after a backup in `<home>/backups` | `sb import --replace --pack ./team.sbkb` |
| ↳ `--dry-run` | Show what would be imported | `sb import --dry-run` |
| `sb export` | Write a dossier as Markdown or JSON, or one repository as a pack | `sb export` |
| ↳ `--repo <REPO>` | Repository identity, name or folder (default: current checkout) | `sb export --repo sample-project` |
| ↳ `--all` | Export every repository | `sb export --all` |
| ↳ `--format <FORMAT>` | md, json or sqlite (a .sbkb pack with sources, context, decisions, tasks and rules; needs `--out`) (default: md) | `sb export --format json` |
| ↳ `--out <FILE>` | Write to a file instead of standard output (not inside a Git repository) | `sb export --out ../sample-dossier.md` |
| `sb sync` | Keep the data folder in a private Git remote, scanned for secrets | `sb sync` |
| ↳ `--remote <URL>` | The private remote to use the first time (origin) | `sb sync --remote https://example.invalid/my-private-dossier.git` |
| ↳ `--no-push` | Commit and merge, but do not push | `sb sync --no-push` |

The publication scan includes unpublished commit messages and changed Git blobs. A finding yields exit code 2. `sb import` requires a linked repository. `sb sync --no-push` can still fetch, commit and update the local data folder. [Publication check](cli/README.md#publication-check)

## MCP

| Command or parameter | Description | Example |
|---|---|---|
| `sb mcp` | Run the MCP server or register it with a client | `sb mcp` |
| `sb mcp install` | Add `sb mcp` to a client's configuration (asked when --client is omitted) | `sb mcp install --client codex` |
| ↳ `--client <CLIENT>` | claude-desktop, claude-code, codex, cursor, vscode, copilot, windsurf, devin or gemini | `sb mcp install --client codex` |
| `sb mcp uninstall` | Remove `sb mcp` from a client's configuration | `sb mcp uninstall --client codex` |
| ↳ `--client <CLIENT>` | Client ID (see sb mcp clients) | `sb mcp uninstall --client codex` |
| `sb mcp config` | Print the entry to add by hand, and the file it goes in | `sb mcp config --client codex` |
| ↳ `--client <CLIENT>` | Client ID (see sb mcp clients) | `sb mcp config --client codex` |
| `sb mcp clients` | List the supported clients and their configuration files | `sb mcp clients` |

Supply `--client` when running without a terminal. Use `sb mcp clients` for supported IDs and configuration paths. [Client setup](cli/README.md#mcp)

### MCP tools

The tool column identifies the tool. The example column supplies its JSON arguments. Use `list_repos` to find repository identities.

| Tool or parameter | Description | Example |
|---|---|---|
| `list_repos` | List the repositories SecondBrain knows, with their open task counts | `{}` |
| `link_repo` | Link a local Git checkout and create its private dossier if needed | `{"path": "/work/sample-project"}` |
| ↳ `path` | Absolute Git checkout path on the MCP server's machine (required) | `{"path": "/work/sample-project"}` |
| ↳ `link_agent_files` | Write the managed agent files (default false) | `{"path": "/work/sample-project", "link_agent_files": true}` |
| `get_context` | Current state, recent decisions and open tasks of a repository | `{"repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| ↳ `budget` | Approximate token budget. State and rules stay complete | `{"repo": "sample-project", "budget": 500}` |
| `list_tasks` | List a repository's tasks; open ones unless status is given | `{"repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| ↳ `status` | Filter by open, all, todo, doing, blocked or done | `{"repo": "sample-project", "status": "open"}` |
| `get_task` | Show one task with its full description | `{"id": 7, "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "repo": "sample-project"}` |
| ↳ `id` | Task number (required) | `{"id": 7, "repo": "sample-project"}` |
| `add_task` | Create a task | `{"title": "Fix the login redirect", "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"title": "Fix the login redirect", "repo": "sample-project"}` |
| ↳ `title` | Task title (required) | `{"title": "Fix the login redirect", "repo": "sample-project"}` |
| ↳ `body` | Task scope and acceptance criteria | `{"title": "Fix the login redirect", "repo": "sample-project", "body": "Preserve the requested return URL"}` |
| ↳ `priority` | Priority from 1 (highest) to 4 | `{"title": "Fix the login redirect", "repo": "sample-project", "priority": 2}` |
| ↳ `needs_user` | Whether the task needs a person's input | `{"title": "Fix the login redirect", "repo": "sample-project", "needs_user": true}` |
| `ready_tasks` | List the tasks that can start now: todo, unblocked by other tasks, not claimed, not waiting on a person | `{"repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| `claim_task` | Take a ready task so no other agent works on it; the claim expires after `minutes` | `{"id": 7, "by": "docs-agent", "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "by": "docs-agent", "repo": "sample-project"}` |
| ↳ `id` | Task number (required) | `{"id": 7, "by": "docs-agent", "repo": "sample-project"}` |
| ↳ `by` | Claim holder. Use the same holder to check claim ownership when updating or releasing (required) | `{"id": 7, "by": "docs-agent", "repo": "sample-project"}` |
| ↳ `minutes` | Claim duration in minutes (default 30) | `{"id": 7, "by": "docs-agent", "repo": "sample-project", "minutes": 15}` |
| `release_task` | Give a claimed task back (it becomes todo again) | `{"id": 7, "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "repo": "sample-project"}` |
| ↳ `id` | Task number (required) | `{"id": 7, "repo": "sample-project"}` |
| ↳ `by` | Claim holder. Use the same holder to check claim ownership when updating or releasing | `{"id": 7, "repo": "sample-project", "by": "docs-agent"}` |
| `update_task` | Change a task's status, title, priority, needs_user flag or body | `{"id": 7, "repo": "sample-project", "status": "done"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "repo": "sample-project", "status": "done"}` |
| ↳ `id` | Task number (required) | `{"id": 7, "repo": "sample-project", "status": "done"}` |
| ↳ `by` | Claim holder. Use the same holder to check claim ownership when updating or releasing | `{"id": 7, "repo": "sample-project", "status": "done", "by": "docs-agent"}` |
| ↳ `status` | Set todo, doing, blocked or done | `{"id": 7, "repo": "sample-project", "status": "done"}` |
| ↳ `title` | Task title | `{"id": 7, "repo": "sample-project", "status": "done", "title": "Fix the login redirect"}` |
| ↳ `priority` | Priority from 1 (highest) to 4 | `{"id": 7, "repo": "sample-project", "status": "done", "priority": 2}` |
| ↳ `needs_user` | Whether the task needs a person's input | `{"id": 7, "repo": "sample-project", "status": "done", "needs_user": true}` |
| ↳ `body` | Task scope and acceptance criteria | `{"id": 7, "repo": "sample-project", "status": "done", "body": "Preserve the requested return URL"}` |
| ↳ `blocked_by` | Task IDs that must finish first. An empty list clears dependencies | `{"id": 7, "repo": "sample-project", "status": "done", "blocked_by": [3, 5]}` |
| `prepare_queue` | List the open tasks that wait for a person and can be prepared now | `{"repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| `prepare_task` | Save the interview answers of one task as its unattended handoff; `ready` clears needs_user, `hold` keeps it. The acceptance command is CLI only | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "ready"}` |
| ↳ `id` | Task number (required) | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "ready"}` |
| ↳ `scope` | Files or areas in scope (required) | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "ready"}` |
| ↳ `acceptance` | Result and acceptance criteria (required) | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "ready"}` |
| ↳ `decision` | `ready` or `hold` (required) | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "hold"}` |
| ↳ `checks`, `commands`, `inputs`, `decisions`, `authorizations` | Optional handoff fields | `{"id": 7, "scope": "cli/src", "acceptance": "tests pass", "decision": "ready", "authorizations": "push approved"}` |
| `add_decision` | Record a durable decision as one dated line | `{"text": "Use SQLite for a local index.", "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"text": "Use SQLite for a local index.", "repo": "sample-project"}` |
| ↳ `text` | Decision and reason on one line (required) | `{"text": "Use SQLite for a local index.", "repo": "sample-project"}` |
| `set_context` | Replace the repository's current-state notes (keep them short) | `{"text": "The API starts in src/main.rs.", "repo": "sample-project", "if_empty": true}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"text": "The API starts in src/main.rs.", "repo": "sample-project", "if_empty": true}` |
| ↳ `text` | New Markdown notes for the current state (required) | `{"text": "The API starts in src/main.rs.", "repo": "sample-project", "if_empty": true}` |
| ↳ `if_empty` | Save only when there is no existing context | `{"text": "The API starts in src/main.rs.", "repo": "sample-project", "if_empty": true}` |
| `get_guide` | Explain SecondBrain workflows and commands | `{"topic": "chat"}` |
| ↳ `topic` | Guide topic (default overview) | `{"topic": "chat"}` |
| `get_rules` | The general rules and the repository's own rules | `{"repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| `set_repo_rules` | Replace the repository's own rules (kept in the private dossier, not in the repository) | `{"text": "Run cargo test before committing.", "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"text": "Run cargo test before committing.", "repo": "sample-project"}` |
| ↳ `text` | Replacement Markdown for repository rules (required) | `{"text": "Run cargo test before committing.", "repo": "sample-project"}` |
| `list_skills` | List the skills kept in SecondBrain with their descriptions | `{}` |
| `get_skill` | Read a skill before doing the kind of work it covers | `{"name": "review-checklist"}` |
| ↳ `name` | Stored skill name (required) | `{"name": "review-checklist"}` |
| `search` | Search context, decisions, tasks and sources; all repositories unless repo is given | `{"query": "login redirect", "repo": "sample-project"}` |
| ↳ `query` | Search terms (required) | `{"query": "login redirect", "repo": "sample-project"}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"query": "login redirect", "repo": "sample-project"}` |
| `add_source` | Store extracted text as a source: title, text, kind, origin, original_path, para, tags, summary, task_id | `{"title": "Supplier contract 2026", "text": "# Contract\n\nRenewal is due in March.", "repo": "sample-project"}` |
| ↳ `title` | Short title (required) | `{"title": "Supplier contract 2026", "text": "# Contract\n\nRenewal is due in March.", "repo": "sample-project"}` |
| ↳ `text` | Extracted text in Markdown, at most 2 MiB (required) | `{"title": "Supplier contract 2026", "text": "# Contract\n\nRenewal is due in March.", "repo": "sample-project"}` |
| ↳ `kind` | file, web, note, chat, connector or media | `{"title": "Supplier contract 2026", "text": "x", "kind": "file"}` |
| ↳ `origin` | URL, connector item or path the text came from; the same origin makes a new revision | `{"title": "Pricing", "text": "x", "origin": "https://example.invalid/pricing"}` |
| ↳ `original_path` | Absolute path of the original file; copied once, never opened again | `{"title": "Contract", "text": "x", "original_path": "/home/user/contract.pdf"}` |
| ↳ `para` | project, area, resource or archive | `{"title": "Contract", "text": "x", "para": "area"}` |
| ↳ `tags` | List of tags | `{"title": "Contract", "text": "x", "tags": ["contract", "2026"]}` |
| ↳ `summary` | Three to five lines on what the source holds | `{"title": "Contract", "text": "x", "summary": "Renewal due in March"}` |
| ↳ `task_id` | Task this source belongs to | `{"title": "Contract", "text": "x", "task_id": 7}` |
| ↳ `allow_sensitive` | Set only after the user agreed to keep text that looks like secrets or personal data | `{"title": "Contract", "text": "x", "allow_sensitive": true}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"title": "Supplier contract 2026", "text": "# Contract\n\nRenewal is due in March.", "repo": "sample-project"}` |
| `list_sources` | List the repository's current sources, newest first, archive last | `{"para": "archive", "repo": "sample-project"}` |
| ↳ `para` | project, area, resource or archive | `{"para": "archive"}` |
| ↳ `tag` | Only sources with this tag | `{"tag": "contract"}` |
| ↳ `task_id` | Only sources of this task | `{"task_id": 7}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"repo": "sample-project"}` |
| `get_source` | Read one source with its summary and chunks | `{"id": 7, "chunk": 2, "repo": "sample-project"}` |
| ↳ `id` | Source number (required) | `{"id": 7}` |
| ↳ `chunk` | Read only this chunk (1-based) | `{"id": 7, "chunk": 2}` |
| ↳ `budget` | Keep the answer within about this many tokens | `{"id": 7, "budget": 500}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "repo": "sample-project"}` |
| `search_sources` | Search the repository's sources (ranked, with snippets); archived sources rank lower | `{"query": "renewal", "repo": "sample-project"}` |
| ↳ `query` | Search terms (required) | `{"query": "renewal"}` |
| ↳ `para` | project, area, resource or archive | `{"query": "renewal", "para": "area"}` |
| ↳ `limit` | Show at most this many sources | `{"query": "renewal", "limit": 5}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"query": "renewal", "repo": "sample-project"}` |
| `update_source` | Reorganize a source: PARA group, title, summary, tags or task; the text and the original stay as they are | `{"id": 7, "para": "archive", "add_tags": ["done"]}` |
| ↳ `id` | Source number (required) | `{"id": 7, "para": "archive"}` |
| ↳ `title` | New title | `{"id": 7, "title": "Supplier contract 2026 (signed)"}` |
| ↳ `para` | project, area, resource or archive | `{"id": 7, "para": "archive"}` |
| ↳ `summary` | New summary | `{"id": 7, "summary": "Renewal due in March"}` |
| ↳ `add_tags` | Tags to add | `{"id": 7, "add_tags": ["done"]}` |
| ↳ `remove_tags` | Tags to remove | `{"id": 7, "remove_tags": ["draft"]}` |
| ↳ `task_id` | Task this source belongs to; 0 clears the link | `{"id": 7, "task_id": 0}` |
| ↳ `repo` | Repository identity, unique name or checkout path. Defaults to the current checkout | `{"id": 7, "repo": "sample-project"}` |
