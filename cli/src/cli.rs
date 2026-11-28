//! Command-line interface: `sb <command>`.

use crate::check;
use crate::doctor;
use crate::guide;
use crate::kb;
use crate::mcp;
use crate::mcp_install;
use crate::migrate;
use crate::ops;
use crate::portable;
use crate::run;
use crate::skills;
use crate::start;
use crate::store::Home;
use crate::sync;
use crate::task::{Status, one_line, parse_ids};
use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(
    name = "sb",
    version,
    about = "Private project context, decisions and tasks for coding agents"
)]
pub struct Cli {
    /// SecondBrain folder (default: SB_HOME, then the user data folder "sb")
    #[arg(long, global = true, value_name = "PATH")]
    pub home: Option<PathBuf>,
    /// Without a command, the start screen is shown
    #[command(subcommand)]
    pub cmd: Option<Cmd>,
}

#[derive(Subcommand)]
pub enum Cmd {
    /// Check recorded checkouts, repair managed files and browse command menus
    Start {
        /// Command area to browse
        #[arg(value_enum)]
        area: Option<start::Area>,
        /// Command and optional subcommands within the area
        #[arg(value_name = "COMMAND", requires = "area")]
        path: Vec<String>,
    },
    /// List every command with its parameters and descriptions
    Commands,
    /// Create the SecondBrain folder
    Init,
    /// Add the current (or given) repository and link its agent files
    Add {
        /// Repository folder (default: the current folder)
        path: Option<PathBuf>,
        /// Files to link: agents, claude, gemini
        #[arg(long, value_delimiter = ',', default_value = "agents,claude")]
        files: Vec<String>,
        /// Do not write any file in the repository
        #[arg(long)]
        no_files: bool,
    },
    /// Remove the SecondBrain block and pointer files from a repository (the dossier stays)
    Unlink {
        /// Repository folder (default: the current folder)
        path: Option<PathBuf>,
    },
    /// Point the dossier of a local repository (no GitHub remote) at the folder it moved to
    Relink {
        /// Identity or name of the dossier, as listed by `sb repos`
        repo: String,
        /// The checkout's new folder (default: the current folder)
        path: Option<PathBuf>,
    },
    /// List the repositories
    Repos,
    /// Print the context of the current repository, or replace it with --set (reads stdin)
    Context {
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long)]
        repo: Option<String>,
        /// Replace the context with the text read from standard input
        #[arg(long)]
        set: bool,
        /// Save initial context only if the dossier still has none (requires --set)
        #[arg(long, requires = "set")]
        if_empty: bool,
        /// Keep the output within about this many tokens (a large state loses whole sections)
        #[arg(long, value_name = "TOKENS", conflicts_with = "set")]
        budget: Option<usize>,
        /// Shorthand for a small budget (1500 tokens unless --budget is given)
        #[arg(long, conflicts_with = "set")]
        compact: bool,
    },
    /// Record a durable decision
    Decide {
        /// Decision and its reason, on one line
        text: String,
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long)]
        repo: Option<String>,
    },
    /// Manage tasks
    Task {
        /// Repository (identity, its last part, or a folder; default: the current one)
        #[arg(long, global = true)]
        repo: Option<String>,
        #[command(subcommand)]
        cmd: TaskCmd,
    },
    /// List the tasks waiting for input and how an agent interviews the owner to prepare them
    Prepare {
        /// Show one task instead of the whole queue
        id: Option<u32>,
        /// Print the queue as JSON
        #[arg(long)]
        json: bool,
        /// Repository (identity, its last part, or a folder; default: the current one)
        #[arg(long)]
        repo: Option<String>,
    },
    /// Search context, decisions and tasks
    Search {
        /// Words to search for in the dossiers
        query: String,
        /// Limit the search to one repository (default: all)
        #[arg(long)]
        repo: Option<String>,
    },
    /// Sources: extracted text of documents, notes and media kept per repository (PARA)
    Kb {
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long, global = true)]
        repo: Option<String>,
        #[command(subcommand)]
        cmd: KbCmd,
    },
    /// General and repository rules
    Rules {
        #[command(subcommand)]
        cmd: RulesCmd,
    },
    /// Skills kept in SecondBrain, read by agents on demand
    Skill {
        #[command(subcommand)]
        cmd: SkillCmd,
    },
    /// Explain the commands and workflows
    Guide {
        /// overview, commands, onboarding, tasks, prepare, chat, sources, rules, skills, run, check or mcp (default: overview)
        topic: Option<String>,
    },
    /// Import the open tasks exported from SecondBrain 4
    Migrate {
        /// Path to the export from SecondBrain 4
        file: PathBuf,
        /// Also link AGENTS.md and CLAUDE.md in each recorded checkout
        #[arg(long)]
        link: bool,
    },
    /// Scan what a push would publish for secrets, personal data and dossier text (exit 2 on findings)
    Check {
        /// Repository folder (default: the current folder)
        path: Option<PathBuf>,
        /// Scan every commit of every branch, not only the unpushed ones
        #[arg(long)]
        history: bool,
        /// Print findings as machine-readable JSON
        #[arg(long)]
        json: bool,
        /// Install a Git pre-push hook that runs `sb check`
        #[arg(long, conflicts_with_all = ["uninstall_hook", "hook"])]
        install_hook: bool,
        /// Remove the pre-push hook installed by sb
        #[arg(long, conflicts_with = "hook")]
        uninstall_hook: bool,
        /// Used by the pre-push hook: reads the pushed refs on standard input
        #[arg(long, hide = true)]
        hook: bool,
    },
    /// Work through the open tasks unattended, one agent process per task, on an sb/run-* branch
    Run {
        /// claude, codex or gemini (asked when omitted)
        #[arg(long)]
        agent: Option<String>,
        /// Any other agent: a command that reads the prompt on standard input
        #[arg(long, conflicts_with = "agent")]
        agent_cmd: Option<String>,
        /// Run only this task
        #[arg(long)]
        task: Option<u32>,
        /// Run at most this many tasks
        #[arg(long)]
        limit: Option<usize>,
        /// Run every ready task
        #[arg(long, conflicts_with = "limit")]
        all: bool,
        /// Model for a known agent (asked for in a terminal, required otherwise)
        #[arg(long)]
        model: Option<String>,
        /// Effort level for Claude or Codex: low, medium, high, xhigh or max
        #[arg(long)]
        effort: Option<String>,
        /// Minutes before an agent is stopped
        #[arg(long, default_value_t = 30)]
        timeout: u64,
        /// Program Claude Code or Gemini CLI may run without asking, such as cargo (repeatable; the programs in each task's acceptance command and Commands handoff are always allowed)
        #[arg(long = "allow-cmd")]
        allow_cmd: Vec<String>,
        /// List the tasks that would run, then stop
        #[arg(long)]
        dry_run: bool,
    },
    /// Find what drifted (folders, links, blocks, MCP registrations); --fix repairs the safe ones (exit 2 if problems remain)
    Doctor {
        /// Repair what can be repaired without a decision
        #[arg(long)]
        fix: bool,
    },
    /// Keep the data folder in a private Git remote and in step between machines (scans for secrets first)
    Sync {
        /// The private remote to use the first time (origin)
        #[arg(long, value_name = "URL")]
        remote: Option<String>,
        /// Commit and merge, but do not push
        #[arg(long)]
        no_push: bool,
    },
    /// Add what a repository's AGENTS.md, CLAUDE.md, GEMINI.md, Cursor and Copilot files say to its rules (reads only)
    Import {
        /// Repository folder (default: the current folder)
        #[arg(conflicts_with_all = ["pack", "repo", "merge", "replace"])]
        path: Option<PathBuf>,
        /// Import a repository pack (.sbkb) written by `sb export --format sqlite`
        #[arg(long, value_name = "FILE")]
        pack: Option<PathBuf>,
        /// With --pack: the repository to import into (must match the pack's identity)
        #[arg(long, requires = "pack")]
        repo: Option<String>,
        /// With --pack: add what is missing and keep the local text (default)
        #[arg(long, requires = "pack", conflicts_with = "replace")]
        merge: bool,
        /// With --pack: make the dossier equal to the pack, after a backup in <home>/backups
        #[arg(long, requires = "pack")]
        replace: bool,
        /// Show what would be imported
        #[arg(long)]
        dry_run: bool,
    },
    /// Write a dossier (or every dossier) as Markdown or JSON, or one repository as a pack (sqlite)
    Export {
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long)]
        repo: Option<String>,
        /// Export every repository
        #[arg(long, conflicts_with = "repo")]
        all: bool,
        /// md, json or sqlite (a .sbkb pack with the sources, context, decisions, tasks and rules; needs --out)
        #[arg(long, default_value = "md")]
        format: String,
        /// Write to a file instead of standard output (not inside a Git repository)
        #[arg(long, value_name = "FILE")]
        out: Option<PathBuf>,
    },
    /// Run the MCP server on standard input and output, or register it with a client
    Mcp {
        #[command(subcommand)]
        cmd: Option<McpCmd>,
    },
}

#[derive(Subcommand)]
pub enum KbCmd {
    /// Store extracted text as a source (reads standard input unless --text-file is given)
    Add {
        /// Short source title
        title: String,
        /// Read the extracted text from this file instead of standard input
        #[arg(long, value_name = "FILE")]
        text_file: Option<PathBuf>,
        /// file, web, note, chat, connector or media (default: file with --original, else note)
        #[arg(long)]
        kind: Option<String>,
        /// Where the text came from (URL, connector item or path); the same origin makes a new revision
        #[arg(long)]
        origin: Option<String>,
        /// Copy this original file into the folder that only you read; sb never opens it afterwards
        #[arg(long, value_name = "FILE")]
        original: Option<PathBuf>,
        /// project, area, resource or archive (default: project with --task, else resource)
        #[arg(long)]
        para: Option<String>,
        /// Tags, comma separated
        #[arg(long, value_delimiter = ',')]
        tag: Vec<String>,
        /// Task this source belongs to
        #[arg(long)]
        task: Option<u32>,
        /// Three to five lines that say what the source holds
        #[arg(long)]
        summary: Option<String>,
        /// Keep the text although it looks like it holds secrets or personal data
        #[arg(long)]
        allow_sensitive: bool,
    },
    /// List the current sources
    List {
        /// Only this PARA group: project, area, resource or archive
        #[arg(long)]
        para: Option<String>,
        /// Only sources with this tag
        #[arg(long)]
        tag: Option<String>,
        /// Only sources of this task
        #[arg(long)]
        task: Option<u32>,
        /// Print sources as machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Show one source with its summary and chunks
    Show {
        /// Source number
        id: i64,
        /// Show only this chunk (1-based)
        #[arg(long)]
        chunk: Option<usize>,
        /// Keep the output within about this many tokens
        #[arg(long, value_name = "TOKENS")]
        budget: Option<usize>,
    },
    /// Search the sources (ranked, with a snippet); archived sources rank lower
    Search {
        /// Words to search for
        query: String,
        /// Only this PARA group
        #[arg(long)]
        para: Option<String>,
        /// Show at most this many sources
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Move a source to another PARA group
    Move {
        /// Source number
        id: i64,
        /// project, area, resource or archive
        para: String,
    },
    /// Add or remove tags on a source
    Tag {
        /// Source number
        id: i64,
        /// Tags to add, comma separated
        #[arg(long, value_delimiter = ',')]
        add: Vec<String>,
        /// Tags to remove, comma separated
        #[arg(long, value_delimiter = ',')]
        remove: Vec<String>,
    },
    /// Delete a source and its chunks (the original file is never deleted)
    Rm {
        /// Source number
        id: i64,
    },
    /// Counts per PARA group, size, and originals without a source
    Stats,
    /// Drop superseded revisions and duplicate chunks, strip repeated headers and blobs, then vacuum
    Compact {
        /// Show what would be removed without changing anything
        #[arg(long)]
        dry_run: bool,
    },
    /// Write one Markdown file per source (with front matter) into an empty folder outside Git
    Export {
        /// Only md is supported
        #[arg(long, default_value = "md")]
        format: String,
        /// The folder to write
        #[arg(long, value_name = "DIR")]
        out: PathBuf,
    },
}

#[derive(Subcommand)]
pub enum McpCmd {
    /// Add `sb mcp` to a client's configuration (asked when --client is omitted)
    Install {
        /// claude-desktop, claude-code, codex, cursor, vscode, copilot, windsurf, devin or gemini
        #[arg(long)]
        client: Option<String>,
    },
    /// Remove `sb mcp` from a client's configuration
    Uninstall {
        /// Client ID (see sb mcp clients)
        #[arg(long)]
        client: Option<String>,
    },
    /// Print the entry to add by hand, and the file it goes in
    Config {
        /// Client ID (see sb mcp clients)
        #[arg(long)]
        client: Option<String>,
    },
    /// List the supported clients and their configuration files
    Clients,
}

#[derive(Subcommand)]
pub enum TaskCmd {
    /// Create a task
    Add {
        /// Short task title
        title: String,
        /// Task scope, inputs and acceptance criteria
        #[arg(long)]
        body: Option<String>,
        /// 1 (highest) to 4
        #[arg(short, long, value_parser = clap::value_parser!(u8).range(1..=4))]
        priority: Option<u8>,
        /// A person must act or decide
        #[arg(long)]
        needs_user: bool,
        /// Ids of tasks that must be done first (comma separated)
        #[arg(long, value_name = "IDS")]
        blocked_by: Option<String>,
        /// A command that must exit 0 before an unattended run marks the task done
        #[arg(long, value_name = "COMMAND")]
        accept: Option<String>,
    },
    /// List open tasks (--all includes done ones)
    List {
        /// Include completed tasks
        #[arg(long)]
        all: bool,
        /// Print tasks as machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// List the tasks that can start now: todo, unblocked, free, not waiting on a person
    Ready {
        /// Print ready tasks as machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Take a ready task for a while (the lease runs out after --minutes)
    Claim {
        /// Task number in the repository
        id: u32,
        /// Who takes it (an agent or a person)
        #[arg(long)]
        by: String,
        /// Minutes before the task claim expires
        #[arg(long, default_value_t = 30)]
        minutes: u64,
    },
    /// Give a claimed task back
    Release {
        /// Task number in the repository
        id: u32,
    },
    /// Show one task
    Show {
        /// Task number in the repository
        id: u32,
    },
    /// Mark a task done
    Done {
        /// Task number in the repository
        id: u32,
    },
    /// Move old done tasks and old decisions to the archive (still searchable)
    Archive {
        /// Archive done tasks and decisions last touched more than this many days ago
        #[arg(long, value_name = "DAYS")]
        older_than: u64,
    },
    /// Interview the owner and prepare a task for unattended work
    Prepare {
        /// Task number in the repository
        id: u32,
    },
    /// Change a task
    Set {
        /// Task number in the repository
        id: u32,
        /// todo, doing, blocked or done
        #[arg(long)]
        status: Option<String>,
        /// Replace the task title
        #[arg(long)]
        title: Option<String>,
        /// New priority from 1 (highest) to 4
        #[arg(short, long, value_parser = clap::value_parser!(u8).range(1..=4))]
        priority: Option<u8>,
        /// Whether a person must act or decide (true or false)
        #[arg(long)]
        needs_user: Option<bool>,
        /// Replace the task description and acceptance criteria
        #[arg(long)]
        body: Option<String>,
        /// Ids of tasks that must be done first (comma separated; empty clears)
        #[arg(long, value_name = "IDS")]
        blocked_by: Option<String>,
        /// The acceptance command (empty clears)
        #[arg(long, value_name = "COMMAND")]
        accept: Option<String>,
    },
}

#[derive(Subcommand)]
pub enum SkillCmd {
    /// List the skills
    List,
    /// Print a skill
    Show {
        /// Skill name
        name: String,
    },
    /// Store or replace a skill (text from --file or standard input)
    Add {
        /// Skill name
        name: String,
        /// Source Markdown file (default: read standard input)
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// Remove a skill
    Remove {
        /// Skill name
        name: String,
    },
}

#[derive(Subcommand)]
pub enum RulesCmd {
    /// Print the general rules and the repository's rules
    Show {
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long)]
        repo: Option<String>,
    },
    /// Replace the repository's rules (or the general ones with --general) from standard input
    Set {
        /// Repository identity, name or folder (default: current checkout)
        #[arg(long, conflicts_with = "general")]
        repo: Option<String>,
        /// Replace the general rules (rules.md) instead
        #[arg(long)]
        general: bool,
    },
    /// Refresh managed instructions in linked repositories or explicit agent files
    Sync {
        /// Global agent instructions file (repeat to select more files)
        #[arg(long, value_name = "FILE")]
        agent_file: Vec<PathBuf>,
        /// Check the selected files without writing (exit 2 if any differ)
        #[arg(long, requires = "agent_file")]
        check: bool,
    },
}

/// An outcome that is not an error but needs a non-zero exit code (for example `sb check` findings).
#[derive(Debug)]
pub struct Exit {
    pub code: i32,
    pub text: String,
}

impl std::fmt::Display for Exit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

impl std::error::Error for Exit {}

fn check(home: &Home, folder: &Path, history: bool, json: bool, hook: bool) -> Result<String> {
    let (root, identity) = ops::checkout(folder)?;
    let root = PathBuf::from(root);
    let dossier = if home.is_initialized() {
        home.find_checkout(&identity, &root)?
    } else {
        None
    };
    let range = if hook {
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input)?;
        check::Range::Revs(check::hook_revs(&input))
    } else if history {
        check::Range::History
    } else {
        check::Range::Unpushed
    };
    let report = check::scan(&root, dossier.as_ref(), &range)?;
    let text = if json {
        serde_json::to_string_pretty(&report.findings)? + "\n"
    } else {
        check::report_text(&report)
    };
    if report.findings.is_empty() {
        Ok(text)
    } else {
        let text = if hook {
            format!("{text}Push blocked by `sb check`.\n")
        } else {
            text
        };
        Err(Exit { code: 2, text }.into())
    }
}

/// What an MCP client should start: this binary, plus SB_HOME when the home is not the default.
fn launch_for(home: &Home, custom_home: bool) -> Result<mcp_install::Launch> {
    let exe = std::env::current_exe()?;
    let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
    let mut command = exe.display().to_string();
    if let Some(stripped) = command.strip_prefix(r"\\?\") {
        command = stripped.to_string();
    }
    let sb_home = if custom_home {
        Some(std::path::absolute(&home.root)?.display().to_string())
    } else {
        None
    };
    Ok(mcp_install::Launch { command, sb_home })
}

/// Runs a command and returns what to print.
pub fn run(cli: Cli, cwd: &Path) -> Result<String> {
    let custom_home =
        cli.home.is_some() || std::env::var_os("SB_HOME").is_some_and(|v| !v.is_empty());
    let cmd = match cli.cmd {
        Some(Cmd::Commands) => return Ok(start::all_commands()),
        Some(Cmd::Start {
            area: Some(area),
            path,
        }) => return start::menu(area, &path),
        None | Some(Cmd::Start { area: None, .. }) => {
            let home = Home::for_start(cli.home.as_deref())?;
            return Ok(start::text(&home, cwd, &launch_for(&home, custom_home)?));
        }
        Some(cmd) => cmd,
    };
    let home = Home::resolve(cli.home.as_deref())?;
    match cmd {
        Cmd::Commands | Cmd::Start { .. } => unreachable!("handled before resolving the home"),
        Cmd::Init => {
            let done = home.init()?;
            let mut s = format!("SecondBrain is ready at {}\n", home.root.display());
            for d in done {
                s.push_str(&format!("- {d}\n"));
            }
            s.push_str("Next: run `sb add` inside each repository; for desktop apps, register `sb mcp` as an MCP server.\n");
            Ok(s)
        }
        Cmd::Add {
            path,
            files,
            no_files,
        } => ops::link_checkout(
            &home,
            path.as_deref().unwrap_or(cwd),
            if no_files { &[] } else { &files },
            false,
        ),
        Cmd::Unlink { path } => {
            home.require()?;
            let folder = path.unwrap_or_else(|| cwd.to_path_buf());
            let (root, identity) = ops::checkout(&folder)?;
            let mut s = String::new();
            for m in ops::unlink_files(Path::new(&root))? {
                s.push_str(&format!("- {m}\n"));
            }
            if let Some(mut d) = home.find_checkout(&identity, Path::new(&root))? {
                d.remove_path(&root);
                d.save_meta()?;
            }
            s.push_str(&format!(
                "Unlinked {identity}; its dossier stays in SecondBrain.\n"
            ));
            Ok(s)
        }
        Cmd::Relink { repo, path } => ops::relink(&home, &repo, path.as_deref().unwrap_or(cwd)),
        Cmd::Repos => {
            home.require()?;
            ops::repos_text(&home)
        }
        Cmd::Context {
            repo,
            set,
            if_empty,
            budget,
            compact,
        } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            if set {
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text)?;
                if if_empty {
                    d.set_initial_context(&text)?;
                    return Ok(format!("Initial context of {} saved.\n", d.meta.identity));
                }
                d.set_context(&text)?;
                return Ok(format!("Context of {} replaced.\n", d.meta.identity));
            }
            ops::context_with_options(
                &home,
                &d,
                budget.filter(|b| *b > 0),
                compact && budget != Some(0),
            )
        }
        Cmd::Decide { text, repo } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            Ok(format!("Recorded {}\n", d.add_decision(&text)?))
        }
        Cmd::Prepare { id, json, repo } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            if json {
                return Ok(serde_json::to_string_pretty(&crate::prepare::queue(&d)?)?
                    + "
");
            }
            crate::prepare::instructions(&d, id)
        }
        Cmd::Task { repo, cmd } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            match cmd {
                TaskCmd::Add {
                    title,
                    body,
                    priority,
                    needs_user,
                    blocked_by,
                    accept,
                } => {
                    let t = d.add_task_with(&title, |task| {
                        task.body = body.as_deref().unwrap_or_default().trim().to_string();
                        task.priority = priority;
                        task.needs_user = needs_user;
                        if let Some(ids) = blocked_by {
                            task.blocked_by = parse_ids(&ids)?;
                        }
                        task.accept = accept.filter(|command| !command.trim().is_empty());
                        Ok(())
                    })?;
                    Ok(format!("Created {}\n", t.summary()))
                }
                TaskCmd::Ready { json } => {
                    let tasks = d.ready_tasks()?;
                    if json {
                        return Ok(serde_json::to_string_pretty(&tasks)? + "\n");
                    }
                    Ok(ops::task_list_text(&tasks))
                }
                TaskCmd::Claim { id, by, minutes } => {
                    let t = d.claim_task(id, &by, minutes)?;
                    Ok(format!("Claimed {} for {minutes} min\n", t.summary()))
                }
                TaskCmd::Release { id } => {
                    Ok(format!("Released {}\n", d.release_task(id)?.summary()))
                }
                TaskCmd::List { all, json } => {
                    let mut tasks = d.tasks()?;
                    if !all {
                        tasks.retain(|t| t.is_open());
                        ops::sort_open(&mut tasks);
                    }
                    if json {
                        return Ok(serde_json::to_string_pretty(&tasks)? + "\n");
                    }
                    Ok(ops::task_list_text(&tasks))
                }
                TaskCmd::Show { id } => Ok(ops::task_text(&d.task(id)?)),
                TaskCmd::Archive { older_than } => {
                    let (tasks, decisions, kept) = d.archive_old(older_than)?;
                    let mut out = format!(
                        "Archived {} done task(s) and {decisions} decision(s) older than {older_than} days\n",
                        tasks.len()
                    );
                    for t in &tasks {
                        out.push_str(&format!("  {}\n", t.summary()));
                    }
                    if kept > 0 {
                        out.push_str(&format!(
                            "Kept {kept} done task(s) that a remaining task still depends on\n"
                        ));
                    }
                    Ok(out)
                }
                TaskCmd::Prepare { id } => crate::prepare::run(
                    &d,
                    id,
                    &mut std::io::stdin().lock(),
                    &mut std::io::stderr().lock(),
                ),
                TaskCmd::Done { id } => Ok(format!(
                    "Done: {}\n",
                    d.set_status(id, Status::Done)?.summary()
                )),
                TaskCmd::Set {
                    id,
                    status,
                    title,
                    priority,
                    needs_user,
                    body,
                    blocked_by,
                    accept,
                } => {
                    if status.is_none()
                        && title.is_none()
                        && priority.is_none()
                        && needs_user.is_none()
                        && body.is_none()
                        && blocked_by.is_none()
                        && accept.is_none()
                    {
                        bail!(
                            "nothing to change: pass --status, --title, --priority, --needs-user, --body, --blocked-by or --accept"
                        );
                    }
                    let t = d.update_task(id, |t| {
                        if let Some(ids) = blocked_by {
                            t.blocked_by = parse_ids(&ids)?;
                            t.blocker_keys.clear();
                        }
                        if let Some(a) = accept {
                            t.accept = (!a.trim().is_empty()).then_some(a);
                        }
                        if let Some(s) = status {
                            t.status = Status::parse(&s)?;
                        }
                        if let Some(s) = title {
                            if s.trim().is_empty() {
                                bail!("the title is empty");
                            }
                            t.title = one_line(&s);
                        }
                        if priority.is_some() {
                            t.priority = priority;
                        }
                        if let Some(b) = needs_user {
                            t.needs_user = b;
                        }
                        if let Some(b) = body {
                            t.body = b.trim().to_string();
                        }
                        Ok(())
                    })?;
                    Ok(format!("Updated {}\n", t.summary()))
                }
            }
        }
        Cmd::Search { query, repo } => {
            home.require()?;
            match repo {
                Some(r) => ops::search(&home, &[home.resolve_repo(Some(&r), cwd)?], &query),
                None => ops::search(&home, &home.dossiers()?, &query),
            }
        }
        Cmd::Rules { cmd } => match cmd {
            RulesCmd::Sync { agent_file, check } => {
                home.require()?;
                if agent_file.is_empty() {
                    return ops::sync_rules(&home);
                }
                let files = agent_file
                    .iter()
                    .map(|path| cwd.join(path))
                    .collect::<Vec<_>>();
                let (text, mismatch) = ops::sync_agent_rules(&home, &files, check)?;
                if mismatch {
                    return Err(Exit { code: 2, text }.into());
                }
                Ok(text)
            }
            RulesCmd::Show { repo } => {
                home.require()?;
                let d = home.resolve_repo(repo.as_deref(), cwd).ok();
                Ok(ops::rules_text(&home, d.as_ref()))
            }
            RulesCmd::Set { repo, general } => {
                home.require()?;
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text)?;
                if general {
                    home.set_rules(&text)?;
                    return Ok("General rules replaced; run `sb rules sync` to update the linked repositories.\n".into());
                }
                let d = home.resolve_repo(repo.as_deref(), cwd)?;
                d.set_rules(&text)?;
                Ok(format!("Rules of {} replaced.\n", d.meta.identity))
            }
        },
        Cmd::Kb { repo, cmd } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            match cmd {
                KbCmd::Add {
                    title,
                    text_file,
                    kind,
                    origin,
                    original,
                    para,
                    tag,
                    task,
                    summary,
                    allow_sensitive,
                } => {
                    let text = match text_file {
                        Some(f) => {
                            let f = cwd.join(f);
                            let len = std::fs::metadata(&f)
                                .with_context(|| format!("reading {}", f.display()))?
                                .len();
                            if len > kb::MAX_TEXT_BYTES as u64 {
                                bail!(
                                    "{} is larger than {} bytes",
                                    f.display(),
                                    kb::MAX_TEXT_BYTES
                                );
                            }
                            std::fs::read_to_string(&f)
                                .with_context(|| format!("reading {}", f.display()))?
                        }
                        None => {
                            let mut text = String::new();
                            std::io::stdin()
                                .take(kb::MAX_TEXT_BYTES as u64 + 1)
                                .read_to_string(&mut text)?;
                            text
                        }
                    };
                    let original = original.map(|p| cwd.join(p));
                    let added = kb::add(
                        &home,
                        &d,
                        kb::NewSource {
                            title: &title,
                            text: &text,
                            kind: kind.as_deref(),
                            origin: origin.as_deref(),
                            original: original.as_deref(),
                            para: para.as_deref(),
                            tags: kb::parse_tags(&tag)?,
                            summary: summary.as_deref(),
                            task,
                            by: Some("cli"),
                            allow_sensitive,
                        },
                    )?;
                    Ok(added.text(&title))
                }
                KbCmd::List {
                    para,
                    tag,
                    task,
                    json,
                } => {
                    let sources = kb::list(
                        &d,
                        &kb::Filter {
                            para: para.as_deref(),
                            tag: tag.as_deref(),
                            task,
                        },
                    )?;
                    if json {
                        Ok(serde_json::to_string_pretty(&kb::list_json(&sources))? + "\n")
                    } else {
                        Ok(kb::list_text(&sources))
                    }
                }
                KbCmd::Show { id, chunk, budget } => {
                    kb::show(&d, id, chunk, budget.filter(|b| *b > 0))
                }
                KbCmd::Search { query, para, limit } => {
                    kb::search_text(&d, &query, para.as_deref(), limit)
                }
                KbCmd::Move { id, para } => {
                    let s = kb::update(
                        &d,
                        id,
                        &kb::Update {
                            para: Some(para),
                            ..Default::default()
                        },
                    )?;
                    Ok(format!("Moved {}\n", kb::line(&s)))
                }
                KbCmd::Tag { id, add, remove } => {
                    if add.is_empty() && remove.is_empty() {
                        bail!("pass --add or --remove");
                    }
                    let s = kb::update(
                        &d,
                        id,
                        &kb::Update {
                            add_tags: add,
                            remove_tags: remove,
                            ..Default::default()
                        },
                    )?;
                    Ok(format!("Updated {}\n", kb::line(&s)))
                }
                KbCmd::Rm { id } => kb::remove(&home, &d, id),
                KbCmd::Stats => kb::stats(&home, &d),
                KbCmd::Compact { dry_run } => Ok(kb::compact(&d, dry_run)?.text()),
                KbCmd::Export { format, out } => {
                    if !format.eq_ignore_ascii_case("md")
                        && !format.eq_ignore_ascii_case("markdown")
                    {
                        bail!("unknown format '{format}' (use md)");
                    }
                    let out = cwd.join(out);
                    portable::ensure_outside_repo(&home, &out)?;
                    kb::export_md(&d, &out)
                }
            }
        }
        Cmd::Skill { cmd } => {
            home.require()?;
            match cmd {
                SkillCmd::List => skills::list_text(&home),
                SkillCmd::Show { name } => skills::show(&home, &name),
                SkillCmd::Remove { name } => skills::remove(&home, &name),
                SkillCmd::Add { name, file } => {
                    let text = match file {
                        Some(f) => std::fs::read_to_string(&f)
                            .with_context(|| format!("reading {}", f.display()))?,
                        None => {
                            let mut t = String::new();
                            std::io::stdin().read_to_string(&mut t)?;
                            t
                        }
                    };
                    skills::add(&home, &name, &text)
                }
            }
        }
        Cmd::Guide { topic } => guide::text(topic.as_deref()).map_err(|e| anyhow::anyhow!(e)),
        Cmd::Migrate { file, link } => migrate::run(&home, &file, link),
        Cmd::Check {
            path,
            history,
            json,
            install_hook,
            uninstall_hook,
            hook,
        } => {
            let folder = path.unwrap_or_else(|| cwd.to_path_buf());
            if install_hook || uninstall_hook {
                let (root, _) = ops::checkout(&folder)?;
                let root = PathBuf::from(root);
                return if install_hook {
                    check::install_hook(&root)
                } else {
                    check::uninstall_hook(&root)
                };
            }
            check(&home, &folder, history, json, hook)
        }
        Cmd::Run {
            agent,
            agent_cmd,
            task,
            limit,
            all,
            model,
            effort,
            timeout,
            allow_cmd,
            dry_run,
        } => {
            let opts = run::RunOptions {
                agent,
                agent_cmd,
                task,
                limit,
                all,
                model,
                effort,
                timeout_minutes: timeout,
                allow_cmd,
                dry_run,
            };
            run::run(&home, cwd, opts, &mut |line| println!("{line}"))
        }
        Cmd::Doctor { fix } => {
            let dirs = mcp_install::Dirs::from_env()?;
            let launch = launch_for(&home, custom_home)?;
            let findings = doctor::run(
                &home,
                &doctor::Options {
                    fix,
                    launch: &launch,
                    dirs: &dirs,
                    external: true,
                },
            )?;
            let text = doctor::text(&findings, fix);
            if doctor::unresolved(&findings) {
                Err(Exit { code: 2, text }.into())
            } else {
                Ok(text)
            }
        }
        Cmd::Import {
            path,
            pack: Some(pack),
            repo,
            replace,
            dry_run,
            ..
        } => {
            debug_assert!(path.is_none());
            home.require()?;
            let pack = cwd.join(pack);
            let identity = kb::pack_identity(&pack)?;
            let d = match repo {
                Some(spec) => home.resolve_repo(Some(&spec), cwd)?,
                None => match home.find(&identity)? {
                    Some(d) => d,
                    None if dry_run => {
                        return Ok(format!(
                            "Dry run: {identity} has no dossier here; a real import would create it and add everything in the pack\n"
                        ));
                    }
                    None => home.create(&identity)?,
                },
            };
            let mode = if replace {
                kb::PackMode::Replace
            } else {
                kb::PackMode::Merge
            };
            kb::import_pack(&home, &d, &pack, mode, dry_run)
        }
        Cmd::Import {
            path,
            dry_run,
            pack: None,
            ..
        } => {
            home.require()?;
            let folder = path.unwrap_or_else(|| cwd.to_path_buf());
            let (root, identity) = ops::checkout(&folder)?;
            let d = home
                .find_checkout(&identity, Path::new(&root))?
                .ok_or_else(|| {
                    anyhow::anyhow!("{identity} is not added yet; run `sb add` first")
                })?;
            portable::import(&d, Path::new(&root), dry_run)
        }
        Cmd::Export {
            repo,
            all,
            format,
            out,
        } => {
            home.require()?;
            if format.eq_ignore_ascii_case("sqlite") {
                if all {
                    bail!("a pack holds one repository; drop --all");
                }
                let Some(file) = out else {
                    bail!("--format sqlite needs --out FILE.sbkb");
                };
                let file = cwd.join(file);
                portable::ensure_outside_repo(&home, &file)?;
                let d = home.resolve_repo(repo.as_deref(), cwd)?;
                return kb::export_pack(&d, &file);
            }
            let dossiers = if all {
                home.dossiers()?
            } else {
                vec![home.resolve_repo(repo.as_deref(), cwd)?]
            };
            let text = portable::export(&dossiers, &format)?;
            match out {
                None => Ok(text),
                Some(file) => {
                    let parent = file
                        .parent()
                        .filter(|p| !p.as_os_str().is_empty())
                        .unwrap_or(cwd);
                    if crate::git::repo_root(parent).is_some() && !file.starts_with(&home.root) {
                        bail!(
                            "{} is inside a Git repository; the dossier must not be written there",
                            file.display()
                        );
                    }
                    crate::store::write_atomic(&file, &text)?;
                    Ok(format!(
                        "Wrote {}
",
                        file.display()
                    ))
                }
            }
        }
        Cmd::Sync { remote, no_push } => sync::run(&home, remote.as_deref(), no_push),
        Cmd::Mcp { cmd: None } => {
            mcp::serve(home)?;
            Ok(String::new())
        }
        Cmd::Mcp { cmd: Some(cmd) } => {
            let dirs = mcp_install::Dirs::from_env()?;
            let launch = launch_for(&home, custom_home)?;
            match cmd {
                McpCmd::Install { client } => {
                    mcp_install::install(&mcp_install::choose(client.as_deref())?, &dirs, &launch)
                }
                McpCmd::Uninstall { client } => {
                    mcp_install::uninstall(&mcp_install::choose(client.as_deref())?, &dirs)
                }
                McpCmd::Config { client } => Ok(mcp_install::config_text(
                    &mcp_install::choose(client.as_deref())?,
                    &dirs,
                    &launch,
                )),
                McpCmd::Clients => {
                    let mut s = String::new();
                    for c in mcp_install::CLIENTS {
                        let place = mcp_install::config_path(c, &dirs)
                            .map(|p| p.display().to_string())
                            .unwrap_or_else(|| "via `claude mcp add`".into());
                        s.push_str(&format!("{:<15} {:<26} {place}\n", c.id, c.name));
                    }
                    Ok(s)
                }
            }
        }
    }
}
