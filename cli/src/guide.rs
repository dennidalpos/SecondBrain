//! The built-in guide: what each command does, for people and for agents (`sb guide`, MCP `get_guide`).

const OVERVIEW: &str = "\
SecondBrain (sb): private context, decisions, tasks, rules and skills for coding agents,
kept in the sb data folder (Windows %LOCALAPPDATA%\\sb, macOS ~/Library/Application Support/sb,
Linux $XDG_DATA_HOME/sb or ~/.local/share/sb; override with SB_HOME), outside your repositories.

Browse commands:      sb start work task
Start of a session:   sb context   (state, repository rules, decisions, open tasks, skills)
During the work:      sb task ... / sb decide \"...\" / sb context --set
Before a push:        sb check

Topics: sb guide <topic>
  commands   every command and what it does
  onboarding analyze a checkout and create its starting dossier
  tasks      working with tasks
  prepare    make tasks that wait for input ready for unattended work
  chat       take one task or work through eligible tasks in the current chat
  sources    add documents, notes and media to a repository and find them again
  rules      general and repository rules
  skills     skills kept in SecondBrain
  run        unattended runs
  check      the publication check
  mcp        the MCP server and its tools
";

const ONBOARDING: &str = "\
Use this workflow when the user wants SecondBrain to manage a new or existing Git checkout
and the dossier or its current context is missing. Inspect the local checkout before writing notes.

1. Identify the checkout root and Git identity. Read any existing context first. Link only the
   intended checkout: `sb init` once per machine, then `sb add [PATH]`. In MCP use `link_repo`
   with `path` (absolute checkout path) and optional `link_agent_files` (default false).
   Existing dossier notes are preserved. Request the missing checkout if you cannot read its files.
2. Read repository instructions, tracked files, README and architecture docs, manifests and
   lockfiles, CI workflows, test configuration and release/deployment scripts. Trace the main
   entry points through the implementation, data and external interfaces. Sample representative
   tests and inspect Git status and relevant history to establish the current baseline.
3. Verify the documented setup, build and test commands where feasible. Record what you ran and
   its result. Record missing access, inputs and checks as open questions. For a new or empty
   repository, capture the user's stated intent and actual scaffold and leave unknown choices open.
4. Write the starting context under Purpose and scope, Structure and entry points, Build and
   verification, Current state, and Open questions. Reference evidence by repository-relative
   path. Keep secrets and personal data out. Only record established rules and decisions, and
   add tasks only for concrete work the user wants tracked.
5. Save privately with `sb context --set --if-empty` (reads the Markdown on standard input),
   or `set_context` with `repo`, `text` and `if_empty: true`. If context already exists, read it
   and reconcile new evidence before an explicit update. Report what was saved and any gaps.
";

const SOURCES: &str = "\
Sources keep what a repository's documents, pages, chats and media say, organized with PARA and
searchable. You extract; sb stores. sb never parses or opens the original file.

PARA: project (tied to a goal or task), area (an ongoing responsibility), resource (reference
material), archive (inactive; still searchable, ranked lower).

1. Read the file with your own tools: text, OCR for images and scans, a transcript with timestamps
   for audio and video, a connector or plugin for Notion, GitHub, Slack and similar. Do not guess.
2. Write the extract as structured Markdown: headings, tables as Markdown, quotes kept exact. Add
   a summary of three to five lines.
3. Ask the user, with the client's structured question tool, for what is unclear: the PARA group,
   the tags, the task it belongs to. Offer two or three options and a recommendation.
4. Store it: `sb kb add \"Title\" --original FILE --para resource --tag a,b --summary \"...\"` (text on
   standard input or --text-file), or the MCP tool add_source with title, text, kind, origin,
   original_path, para, tags, summary and task_id. The original is copied once to a folder only
   the user reads; after that sb never opens it.
5. If the text looks like secrets or personal data, add_source refuses and lists the kinds. Ask the
   user; only then repeat with allow_sensitive.
6. The same origin stored again becomes a new revision; the same text twice is refused.

Find and read: `sb kb search words`, `sb kb show ID [--chunk N] [--budget TOKENS]`, MCP search_sources
and get_source. `sb search` also lists source hits as src#N. Organize: `sb kb move`, `sb kb tag`,
MCP update_source. `sb kb stats` shows counts and originals without a source. Sources stay on this
machine (kb.db is not synchronized); originals are never exported or synchronized.
";

const CHAT: &str = "\
Ask the agent in the current chat: 'Start task #7 in this repository', 'Run the next 3 eligible
tasks here', or 'Work through all eligible tasks in this repository'. The agent needs access to
the checkout and the tools needed to do the work. A read-only chat can still show the queue.

1. Use get_context (`repo`, optional `budget`) and ready_tasks (`repo`). For one task, use
   get_task (`repo`, `id`) and check that the requested task is eligible. For a batch, follow the
   order returned by ready_tasks and the user's limit. Refresh eligibility after each task.
   Keep track of attempted IDs so a released task is tried at most once per batch.
2. Claim one task immediately before starting it with claim_task (`repo`, `id`, `by`, optional
   `minutes`, default 30). Use a unique holder for this session. If a claim fails, refresh the
   queue for a batch or report the blocker for a specific task. Check the task scope and acceptance.
3. Work in this chat and run the applicable checks in the checkout, including any acceptance
   command from get_task. Use update_task (`repo`, `id`, `by`, `status: done`) only after meeting
   acceptance. For a blocker set `status: blocked` and record what is missing. Set `needs_user`
   when a person must act. Use release_task (`repo`, `id`, `by`) to give back an unfinished task.
   Pass the same `by` as in claim_task so an expired or reassigned claim cannot be updated.
   Summarize completed and remaining tasks.

Before the first claim, settle ambiguous choices and collect the approvals the work needs (push,
installs, network, deletions, accounts) with the client's structured question tool, so the batch
is not interrupted. If a task still needs a person, set needs_user and record what is missing, or prepare it
with `sb guide prepare` (interview, then prepare_task).

MCP manages the queue and claims. The current chat agent performs the work. The separate
unattended runner that launches fresh agent processes is `sb run`.
";

const TASKS: &str = "\
sb task add \"title\" [--body text] [-p 1-4] [--needs-user] [--blocked-by 3,5] [--accept \"command\"]
sb task list [--all] [--json]
sb task show <id>
sb task prepare <id>         interview to prepare a task for unattended work
sb task set <id> [--status todo|doing|blocked|done] [--title] [-p] [--needs-user true|false] [--body]
sb task done <id>
sb task ready [--json]       tasks that can start now: todo, unblocked, free, not waiting on a person
sb task claim <id> --by NAME [--minutes 30]   take a ready task; one claimer wins, the lease expires
sb task release <id>         give a claimed task back

Dependencies: --blocked-by lists the tasks that must be done first (loops are refused); `sb task list`
shows what each task waits for. Writers take a lock on the task folder, so several agents (CLI and MCP)
get distinct ids and a task is claimed once. MCP tools: ready_tasks, claim_task, release_task.
Unattended runs recompute the ready queue after every task. --accept is a command that must exit 0 in the
repository before `sb run` marks the task done; it can only be set from the CLI, never through MCP.

Use --needs-user when a person must act or decide. The prepare interview saves scope, checks,
acceptance, inputs, decisions and the approvals needed before the run starts. Choose ready, hold or cancel. Existing dependencies still apply.
For the current chat agent instead of a separate runner, use `sb guide chat` or `get_guide` with topic `chat`.
";

const RULES: &str = "\
General rules apply to every repository; repository rules apply to one.

sb rules show [--repo R]     print the general rules and the repository's rules
sb rules set [--repo R]      replace the repository's rules with the text on standard input
sb rules set --general       replace the general rules (rules.md) from standard input
sb rules sync                copy the general rules into the block of every linked AGENTS.md
sb rules sync --agent-file ./agent-profile/AGENTS.md
                             install or update the same versioned block in a global instructions file
sb rules sync --check --agent-file ./agent-profile/AGENTS.md
                             report alignment without writing; repeat --agent-file to check more files

General rules are copied into AGENTS.md (shared text). Repository rules stay in the private
dossier: agents read them in `sb context`, and `sb run` adds them to each prompt.
After changing the general rules, run `sb rules sync` and refresh any global agent files you manage.
The directive version identifies the exact normalized managed content, including shared rules.
";

const SKILLS: &str = "\
Skills are instructions kept once in SecondBrain (<data folder>/skills/<name>/SKILL.md) and
read by any agent when it needs them. Nothing is written to your repositories.

sb skill list                list the skills with their descriptions
sb skill show <name>         print a skill: read it before doing the kind of work it covers
sb skill add <name> [--file SKILL.md]   store or replace a skill (text from the file or standard input)
sb skill remove <name>

A skill is a Markdown file with front matter (name, description), then the instructions.
`sb context` lists the available skills; MCP clients use list_skills and get_skill.
";

const RUN: &str = "\
sb run [--agent claude|codex|gemini | --agent-cmd \"cmd\"] [--model m] [--effort e] [--task id | --limit n | --all] [--timeout min] [--dry-run]

Works through the ready tasks (todo, unblocked, free, not needs-user), one fresh agent process per task,
on an sb/run-* branch. The ready queue is recomputed after every task.

Before the queue starts the model, the effort and the number of tasks are settled. In a terminal sb lists
the models and efforts it knows for the agent and asks. Without a terminal, select a built-in agent and
model with --agent and --model, then use --task, --limit or --all. --effort is optional. A custom
--agent-cmd owns its model choice. A task with an --accept command is marked done only when that
command exits 0.
sb commits task changes locally. Review the run branch before merging.
";

const CHECK: &str = "\
sb check [--history] [--json]     scan the working tree and unpushed commits (exit 2 on findings)
sb check --install-hook           Git pre-push hook that blocks a push with findings
sb check --uninstall-hook

Finds secrets, personal data and text copied from the dossier. Silence a reviewed false positive
with `sb-check: ignore` on the line or an entry in .sbcheck-ignore.
";

const PREPARE: &str = "Make every task that waits for a person ready for unattended work.

CLI:  sb prepare [id] [--json]   list the queue (or one task) and these instructions
      sb task prepare <id>       the same interview in a terminal, one line per answer

Agent flow (MCP, with the client's structured question tool, for example AskUserQuestion):
1. prepare_queue lists the tasks (open, needs a person, not claimed).
2. For each task read get_task, then ask the owner. Offer two or three concrete options with a
   recommendation: scope (required), acceptance (required), checks, programs the agent may run,
   inputs or access, decisions, approvals (push, installs, network, deletions, accounts).
3. Save with prepare_task (`id`, `scope`, `acceptance`, optional fields, `decision`). Use ready
   when the agent has everything (needs_user is cleared), hold when a person must still act.
   Existing dependencies still apply. The acceptance command is set from the CLI only
   (sb task set <id> --accept \"command\").
4. Never guess an answer. Skip a task the owner cannot answer now. Summarize ready and held tasks,
   then suggest sb run --dry-run.
";

const MCP: &str = "\
sb mcp                       serve MCP on standard input and output
sb mcp install [--client c]  register it (claude-desktop, claude-code, codex, cursor, vscode, copilot, windsurf, devin, gemini)
sb mcp uninstall|config|clients

Tools: list_repos, link_repo, get_context, list_tasks, get_task, add_task, update_task, ready_tasks, claim_task,
release_task, prepare_queue, prepare_task, add_decision, set_context, search, get_guide, get_rules, set_repo_rules, list_skills, get_skill.
";

/// The guide text for a topic, or the overview when none is given.
pub fn text(topic: Option<&str>) -> Result<String, String> {
    let t = match topic.map(|t| t.trim().to_lowercase()).as_deref() {
        None | Some("") | Some("overview") => OVERVIEW,
        Some("commands") => return Ok(crate::start::all_commands()),
        Some("onboarding") => ONBOARDING,
        Some("tasks") => TASKS,
        Some("prepare") => PREPARE,
        Some("chat") => CHAT,
        Some("sources") => SOURCES,
        Some("rules") => RULES,
        Some("skills") => SKILLS,
        Some("run") => RUN,
        Some("check") => CHECK,
        Some("mcp") => MCP,
        Some(other) => {
            return Err(format!(
                "unknown topic '{other}'; use overview, commands, onboarding, tasks, prepare, chat, sources, rules, skills, run, check or mcp"
            ));
        }
    };
    Ok(t.to_string())
}
