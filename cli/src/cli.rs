//! Command-line interface: `sb <command>`.

use crate::check;
use crate::mcp;
use crate::mcp_install;
use crate::migrate;
use crate::ops;
use crate::run;
use crate::store::Home;
use crate::task::{Status, one_line};
use anyhow::{Result, bail};
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
    /// SecondBrain folder (default: SB_HOME, then ~/.secondbrain)
    #[arg(long, global = true, value_name = "PATH")]
    pub home: Option<PathBuf>,
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Subcommand)]
pub enum Cmd {
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
    /// List the repositories
    Repos,
    /// Print the context of the current repository, or replace it with --set (reads stdin)
    Context {
        #[arg(long)]
        repo: Option<String>,
        /// Replace the context with the text read from standard input
        #[arg(long)]
        set: bool,
    },
    /// Record a durable decision
    Decide {
        text: String,
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
    /// Search context, decisions and tasks
    Search {
        query: String,
        /// Limit the search to one repository (default: all)
        #[arg(long)]
        repo: Option<String>,
    },
    /// Shared rules
    Rules {
        #[command(subcommand)]
        cmd: RulesCmd,
    },
    /// Import the open tasks exported from SecondBrain 4
    Migrate {
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
        /// Minutes before an agent is stopped
        #[arg(long, default_value_t = 30)]
        timeout: u64,
        /// List the tasks that would run, then stop
        #[arg(long)]
        dry_run: bool,
    },
    /// Run the MCP server on standard input and output, or register it with a client
    Mcp {
        #[command(subcommand)]
        cmd: Option<McpCmd>,
    },
}

#[derive(Subcommand)]
pub enum McpCmd {
    /// Add `sb mcp` to a client's configuration (asked when --client is omitted)
    Install {
        /// claude-desktop, claude-code, codex, cursor, vscode, windsurf or gemini
        #[arg(long)]
        client: Option<String>,
    },
    /// Remove `sb mcp` from a client's configuration
    Uninstall {
        #[arg(long)]
        client: Option<String>,
    },
    /// Print the entry to add by hand, and the file it goes in
    Config {
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
        title: String,
        #[arg(long)]
        body: Option<String>,
        /// 1 (highest) to 4
        #[arg(short, long, value_parser = clap::value_parser!(u8).range(1..=4))]
        priority: Option<u8>,
        /// A person must act or decide
        #[arg(long)]
        needs_user: bool,
    },
    /// List open tasks (--all includes done ones)
    List {
        #[arg(long)]
        all: bool,
        #[arg(long)]
        json: bool,
    },
    /// Show one task
    Show { id: u32 },
    /// Mark a task done
    Done { id: u32 },
    /// Change a task
    Set {
        id: u32,
        /// todo, doing, blocked or done
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(short, long, value_parser = clap::value_parser!(u8).range(1..=4))]
        priority: Option<u8>,
        #[arg(long)]
        needs_user: Option<bool>,
        #[arg(long)]
        body: Option<String>,
    },
}

#[derive(Subcommand)]
pub enum RulesCmd {
    /// Rewrite the SecondBrain block in every linked repository from rules.md
    Sync,
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
        home.find(&identity)?
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

/// Runs a command and returns what to print.
pub fn run(cli: Cli, cwd: &Path) -> Result<String> {
    let custom_home =
        cli.home.is_some() || std::env::var_os("SB_HOME").is_some_and(|v| !v.is_empty());
    let home = Home::resolve(cli.home.as_deref())?;
    match cli.cmd {
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
        } => {
            home.require()?;
            let folder = path.unwrap_or_else(|| cwd.to_path_buf());
            let (root, identity) = ops::checkout(&folder)?;
            let (mut d, created) = home.find_or_create(&identity)?;
            if d.add_path(&root) {
                d.save_meta()?;
            }
            let mut s = format!(
                "{} {identity}\n",
                if created { "Added" } else { "Already added:" }
            );
            if !no_files {
                for m in ops::link_files(Path::new(&root), &home.rules(), &files)? {
                    s.push_str(&format!("- {m}\n"));
                }
            }
            s.push_str(&format!("Dossier: {}\n", d.dir.display()));
            Ok(s)
        }
        Cmd::Unlink { path } => {
            home.require()?;
            let folder = path.unwrap_or_else(|| cwd.to_path_buf());
            let (root, identity) = ops::checkout(&folder)?;
            let mut s = String::new();
            for m in ops::unlink_files(Path::new(&root))? {
                s.push_str(&format!("- {m}\n"));
            }
            if let Some(mut d) = home.find(&identity)? {
                d.remove_path(&root);
                d.save_meta()?;
            }
            s.push_str(&format!(
                "Unlinked {identity}; its dossier stays in SecondBrain.\n"
            ));
            Ok(s)
        }
        Cmd::Repos => {
            home.require()?;
            ops::repos_text(&home)
        }
        Cmd::Context { repo, set } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            if set {
                let mut text = String::new();
                std::io::stdin().read_to_string(&mut text)?;
                d.set_context(&text)?;
                return Ok(format!("Context of {} replaced.\n", d.meta.identity));
            }
            ops::context_text(&d)
        }
        Cmd::Decide { text, repo } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            Ok(format!("Recorded {}\n", d.add_decision(&text)?))
        }
        Cmd::Task { repo, cmd } => {
            let d = home.resolve_repo(repo.as_deref(), cwd)?;
            match cmd {
                TaskCmd::Add {
                    title,
                    body,
                    priority,
                    needs_user,
                } => {
                    let t = d.add_task(
                        &title,
                        body.as_deref().unwrap_or_default(),
                        priority,
                        needs_user,
                    )?;
                    Ok(format!("Created {}\n", t.summary()))
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
                } => {
                    let mut t = d.task(id)?;
                    if status.is_none()
                        && title.is_none()
                        && priority.is_none()
                        && needs_user.is_none()
                        && body.is_none()
                    {
                        bail!(
                            "nothing to change: pass --status, --title, --priority, --needs-user or --body"
                        );
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
                    t.updated = crate::date::today();
                    d.save_task(&t)?;
                    Ok(format!("Updated {}\n", t.summary()))
                }
            }
        }
        Cmd::Search { query, repo } => {
            home.require()?;
            match repo {
                Some(r) => ops::search_text(&[home.resolve_repo(Some(&r), cwd)?], &query),
                None => ops::search_text(&home.dossiers()?, &query),
            }
        }
        Cmd::Rules {
            cmd: RulesCmd::Sync,
        } => {
            home.require()?;
            ops::sync_rules(&home)
        }
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
            timeout,
            dry_run,
        } => {
            let opts = run::RunOptions {
                agent,
                agent_cmd,
                task,
                limit,
                timeout_minutes: timeout,
                dry_run,
            };
            run::run(&home, cwd, opts, &mut |line| println!("{line}"))
        }
        Cmd::Mcp { cmd: None } => {
            mcp::serve(home)?;
            Ok(String::new())
        }
        Cmd::Mcp { cmd: Some(cmd) } => {
            let dirs = mcp_install::Dirs::from_env()?;
            let exe = std::env::current_exe()?;
            let exe = std::fs::canonicalize(&exe).unwrap_or(exe);
            let mut command = exe.display().to_string();
            if let Some(stripped) = command.strip_prefix(r"\\?\") {
                command = stripped.to_string();
            }
            let launch = mcp_install::Launch {
                command,
                sb_home: custom_home.then(|| home.root.display().to_string()),
            };
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
