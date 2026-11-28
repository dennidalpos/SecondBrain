//! The start screen: `sb start`, and `sb` without a command.
//!
//! The dashboard checks local setup and realigns managed checkout files. Command menus are
//! available without reading or changing the home or repository.

use crate::cli::Cli;
use crate::doctor;
use crate::executable;
use crate::mcp_install::{Dirs, Launch};
use crate::ops;
use crate::store::{Dossier, Home};
use anyhow::{Result, bail};
use clap::{CommandFactory, ValueEnum};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

mod examples;

const COMMON_OPTIONS: &str = "\nCommon options\n  --home <PATH>  Use a different data folder (default: SB_HOME, then the user data folder)  Example: sb --home ./scratch-data init\n  -h, --help     Show command help  Example: sb task add --help\n  -V, --version  Show the installed version  Example: sb --version\n";

#[derive(Clone, Copy, PartialEq, ValueEnum)]
pub enum Area {
    Setup,
    Work,
    Rules,
    Publish,
    Help,
}

struct Group {
    area: Area,
    title: &'static str,
    description: &'static str,
    commands: &'static [(&'static str, &'static str)],
}

impl Group {
    fn route(&self) -> String {
        let value = self.area.to_possible_value().expect("visible area");
        format!("sb start {}", value.get_name())
    }
}

const GROUPS: &[Group] = &[
    Group {
        area: Area::Setup,
        title: "Set up",
        description: "Initialize, link and diagnose repositories",
        commands: &[
            ("init", "Create the SecondBrain folder"),
            ("add", "Add the current repository and link its agent files"),
            ("unlink", "Remove the SecondBrain block from a repository"),
            (
                "relink",
                "Point a local repository's dossier at its new folder",
            ),
            ("repos", "List the repositories"),
            (
                "doctor",
                "Find and repair drifted folders, links and MCP registrations",
            ),
        ],
    },
    Group {
        area: Area::Work,
        title: "Work",
        description: "Context, decisions, tasks, search and runs",
        commands: &[
            (
                "context",
                "Print the repository context (--set replaces it)",
            ),
            ("decide", "Record a durable decision"),
            ("task", "Manage tasks, claims and unattended handoffs"),
            (
                "prepare",
                "List tasks waiting for input and how an agent interviews you to prepare them",
            ),
            ("search", "Search context, decisions and tasks"),
            (
                "kb",
                "Keep sources per repository: add, search, organize with PARA",
            ),
            (
                "run",
                "Work through the open tasks unattended, one agent per task",
            ),
        ],
    },
    Group {
        area: Area::Rules,
        title: "Rules and skills",
        description: "Manage rules and reusable skills",
        commands: &[
            ("rules", "General and repository rules: show, set, sync"),
            (
                "skill",
                "Skills kept in SecondBrain: list, show, add, remove",
            ),
        ],
    },
    Group {
        area: Area::Publish,
        title: "Publish and connect",
        description: "Check changes, sync data and connect clients",
        commands: &[
            (
                "check",
                "Scan a push for secrets, personal data and dossier text",
            ),
            ("mcp", "Run the MCP server or register it with a client"),
            (
                "migrate",
                "Import the open tasks exported from SecondBrain 4",
            ),
            (
                "import",
                "Add a repository's AGENTS.md, CLAUDE.md and Cursor rules to its rules",
            ),
            ("export", "Write a dossier as Markdown or JSON"),
            (
                "sync",
                "Keep the data folder in a private Git remote, scanned for secrets",
            ),
        ],
    },
    Group {
        area: Area::Help,
        title: "Help",
        description: "Start screen, full command list and guides",
        commands: &[
            ("start", "Show the start screen: status and the next step"),
            ("commands", "List every command with its parameters"),
            ("guide", "Explain commands and workflows"),
        ],
    },
];

fn command_tree() -> clap::Command {
    let mut root = Cli::command();
    root.build();
    root
}

/// Every command with its description, by area.
pub fn all_commands() -> String {
    let mut s = String::new();
    let root = command_tree();
    for (i, group) in GROUPS.iter().enumerate() {
        if i > 0 {
            s.push('\n');
        }
        s.push_str(&format!("{}\n", group.title));
        for (name, about) in group.commands {
            if let Some(cmd) = root.find_subcommand(name) {
                let example = examples::invocation(&format!("sb {name}"), cmd, None);
                s.push_str(&format!("  sb {name:<9} {about}  Example: {example}\n"));
                push_usage(&mut s, &format!("sb {name}"), cmd);
            }
        }
        if group.area == Area::Help {
            s.push_str("  sb         Open the start screen  Example: sb\n  sb help    Show help for a command path  Example: sb help task add\n    [COMMAND...]  Command and optional subcommand  Example: sb help task add\n");
        }
    }
    s.push_str(COMMON_OPTIONS);
    s
}

/// Walk the same command tree used by clap, without running any of its commands.
pub fn menu(area: Area, path: &[String]) -> Result<String> {
    let group = GROUPS
        .iter()
        .find(|group| group.area == area)
        .expect("listed area");
    let route = group.route();
    let root = command_tree();
    if path.is_empty() {
        let mut s = format!("{}\n\nCommands\n", group.title);
        for (name, about) in group.commands {
            if let Some(cmd) = root.find_subcommand(name) {
                let example = examples::invocation(&format!("sb {name}"), cmd, None);
                s.push_str(&format!("  sb {name:<9} {about}  Example: {example}\n"));
                push_usage(&mut s, &format!("sb {name}"), cmd);
            }
        }
        s.push_str(COMMON_OPTIONS);
        s.push_str(&format!("\nDetails: {route} <command>\nBack: sb start\n"));
        return Ok(s);
    }

    let first = &path[0];
    let Some((_, about)) = group.commands.iter().find(|(name, _)| name == first) else {
        bail!("'{first}' is not in {}. See {route}.", group.title);
    };
    let mut cmd = root.find_subcommand(first).expect("listed command");
    let mut parent = route.clone();
    let mut current = format!("{route} {first}");
    let mut invocation = format!("sb {first}");
    for name in &path[1..] {
        let Some(child) = visible_subcommands(cmd).find(|child| child.get_name() == name) else {
            bail!("'{name}' is not a subcommand of '{invocation}'. See {current}.");
        };
        cmd = child;
        parent = current.clone();
        current.push_str(&format!(" {name}"));
        invocation.push_str(&format!(" {name}"));
    }

    let description = if path.len() == 1 {
        about.to_string()
    } else {
        cmd.get_about().map(ToString::to_string).unwrap_or_default()
    };
    let example = examples::invocation(&invocation, cmd, None);
    let mut s = format!("{invocation}  {description}  Example: {example}\n");
    push_parameters(&mut s, &invocation, cmd, "  ");
    if visible_subcommands(cmd).next().is_some() {
        s.push_str("\nSubcommands\n");
        for child in visible_subcommands(cmd) {
            let name = child.get_name();
            let about = child
                .get_about()
                .map(ToString::to_string)
                .unwrap_or_default();
            let child_path = format!("{invocation} {name}");
            let example = examples::invocation(&child_path, child, None);
            s.push_str(&format!(
                "  {invocation} {name:<9} {about}  Example: {example}\n"
            ));
            push_parameters(&mut s, &child_path, child, "    ");
        }
        s.push_str(&format!("\nDetails: {current} <subcommand>\n"));
    }
    s.push_str(COMMON_OPTIONS);
    s.push_str(&format!("\nUsage: {invocation} --help\nBack: {parent}\n"));
    Ok(s)
}

fn visible_subcommands(cmd: &clap::Command) -> impl Iterator<Item = &clap::Command> {
    cmd.get_subcommands()
        .filter(|child| child.get_name() != "help" && !child.is_hide_set())
}

fn push_parameters(out: &mut String, prefix: &str, cmd: &clap::Command, indent: &str) {
    for arg in cmd.get_arguments().filter(|arg| {
        !arg.is_hide_set() && !matches!(arg.get_id().as_str(), "help" | "version" | "home")
    }) {
        let mut value = arg
            .get_value_names()
            .and_then(|names| names.first())
            .map_or_else(|| arg.get_id().as_str().to_uppercase(), ToString::to_string);
        if arg.is_positional()
            && arg
                .get_num_args()
                .is_some_and(|count| count.max_values() > 1)
        {
            value.push_str("...");
        }
        let label = match arg.get_long() {
            Some(long) => {
                let mut label = format!("--{long}");
                if let Some(short) = arg.get_short() {
                    label = format!("-{short}, {label}");
                }
                if arg.get_action().takes_values() {
                    label.push_str(&format!(" <{value}>"));
                }
                label
            }
            None => format!("<{value}>"),
        };
        let help = arg.get_help().map(ToString::to_string).unwrap_or_default();
        let required = if arg.is_required_set() {
            " (required)"
        } else {
            ""
        };
        let defaults = arg.get_default_values();
        let default = if arg.get_action().takes_values() && !defaults.is_empty() {
            let values = defaults
                .iter()
                .map(|value| value.to_string_lossy())
                .collect::<Vec<_>>()
                .join(", ");
            format!(" (default: {values})")
        } else {
            String::new()
        };
        let example = examples::invocation(prefix, cmd, Some(arg));
        out.push_str(&format!(
            "{indent}{label}  {help}{required}{default}  Example: {example}\n"
        ));
    }
}

fn push_usage(out: &mut String, prefix: &str, cmd: &clap::Command) {
    push_parameters(out, prefix, cmd, "    ");
    for child in visible_subcommands(cmd) {
        let about = child
            .get_about()
            .map(ToString::to_string)
            .unwrap_or_default();
        let child_path = format!("{prefix} {}", child.get_name());
        let example = examples::invocation(&child_path, child, None);
        out.push_str(&format!("    {child_path}  {about}  Example: {example}\n"));
        push_parameters(out, &child_path, child, "      ");
    }
}

struct Checkout {
    root: String,
    identity: String,
    github: Option<String>,
    hook: &'static str,
    dossier: Option<Repo>,
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Ready,
    NeedsInput,
    Doing,
    Blocked,
}

struct TaskLine {
    id: u32,
    title: String,
    priority: Option<u8>,
    kind: Kind,
    waiting_on: Vec<u32>,
}

struct Repo {
    recorded: bool,
    open: usize,
    ready: usize,
    needs_user: usize,
    /// Ready tasks that have no acceptance command.
    unchecked: Vec<u32>,
    prepare: Option<(u32, bool)>,
    context_age: Option<u64>,
    /// Open tasks: ready first, then waiting on a person, in progress and blocked.
    lines: Vec<TaskLine>,
}

/// Most task rows shown on the dashboard.
const TASK_ROWS: usize = 8;
/// Longest task title shown on the dashboard.
const TITLE_WIDTH: usize = 64;

struct Facts {
    initialized: bool,
    home: String,
    checkout: Option<Checkout>,
    health: Option<doctor::StartupHealth>,
    dossier_error: Option<String>,
    executable: executable::Status,
    /// COMMANDS.md in a known source checkout of SecondBrain, when one exists.
    commands_doc: Option<String>,
}

impl Facts {
    fn repo(&self) -> Option<&Repo> {
        self.checkout.as_ref()?.dossier.as_ref()
    }

    fn problems(&self) -> usize {
        self.health.as_ref().map_or(0, |h| {
            h.findings
                .iter()
                .filter(|f| f.state != doctor::State::Fixed)
                .count()
        }) + usize::from(self.dossier_error.is_some())
    }
}

fn repo_facts(d: &Dossier, root: &str) -> Repo {
    let tasks = d.tasks().unwrap_or_default();
    let open = tasks.iter().filter(|t| t.is_open()).count();
    let now = crate::date::now_secs();
    let ready = tasks
        .iter()
        .filter(|t| crate::store::is_ready(t, &tasks, now))
        .count();
    let needs_user = tasks.iter().filter(|t| t.is_open() && t.needs_user).count();
    let prepare = tasks
        .iter()
        .filter(|t| crate::prepare::can_prepare(t, now))
        .min_by_key(|t| (!t.needs_user, t.priority.unwrap_or(9), t.id))
        .map(|t| (t.id, t.needs_user));
    let context_age = (!d.context().trim().is_empty()).then(|| {
        fs::metadata(d.dir.join("context.md"))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| SystemTime::now().duration_since(m).ok())
            .map_or(0, |age| age.as_secs() / 86_400)
    });
    let mut lines: Vec<TaskLine> = tasks
        .iter()
        .filter(|t| t.is_open())
        .map(|t| {
            let waiting_on: Vec<u32> = t
                .blocked_by
                .iter()
                .copied()
                .filter(|id| tasks.iter().any(|o| o.id == *id && o.is_open()))
                .collect();
            let kind = if crate::store::is_ready(t, &tasks, now) {
                Kind::Ready
            } else if t.needs_user {
                Kind::NeedsInput
            } else if t.status == crate::task::Status::Doing && t.is_claimed(now) {
                Kind::Doing
            } else {
                Kind::Blocked
            };
            TaskLine {
                id: t.id,
                title: t.title.clone(),
                priority: t.priority,
                kind,
                waiting_on,
            }
        })
        .collect();
    lines.sort_by_key(|l| (l.kind as u8, l.priority.unwrap_or(9), l.id));
    let unchecked = tasks
        .iter()
        .filter(|t| crate::store::is_ready(t, &tasks, now) && t.accept.is_none())
        .map(|t| t.id)
        .collect();
    Repo {
        recorded: doctor::recorded_checkout(d, root),
        open,
        ready,
        needs_user,
        unchecked,
        prepare,
        context_age,
        lines,
    }
}

fn github_url(identity: &str) -> Option<String> {
    let path = identity.strip_prefix("github.com/")?;
    let (owner, repo) = path.split_once('/')?;
    let safe = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    };
    (safe(owner) && safe(repo)).then(|| format!("https://github.com/{path}"))
}

fn gather(home: &Home, cwd: &Path, launch: &Launch) -> Facts {
    let initialized = home.is_initialized();
    let location = ops::checkout(cwd).ok();
    let source_identity = crate::git::normalize_remote(env!("CARGO_PKG_REPOSITORY"));
    let mut sources: Vec<PathBuf> = source_identity
        .as_ref()
        .and_then(|identity| home.find(identity).ok().flatten())
        .into_iter()
        .flat_map(|dossier| dossier.meta.paths)
        .filter_map(|path| {
            let root = PathBuf::from(path);
            let (actual, identity) = ops::checkout(&root).ok()?;
            (source_identity.as_ref() == Some(&identity)).then(|| PathBuf::from(actual))
        })
        .collect();
    if let Some((root, identity)) = &location
        && source_identity.as_ref() == Some(identity)
    {
        sources.push(PathBuf::from(root));
    }
    sources.sort();
    sources.dedup();
    let commands_doc = sources
        .iter()
        .map(|root| root.join("COMMANDS.md"))
        .find(|path| path.is_file())
        .map(|path| path.display().to_string());
    let executable = executable::Status::inspect(&launch.command, &sources);
    let dossier = if initialized {
        location
            .as_ref()
            .map(|(root, identity)| home.find_checkout(identity, Path::new(root)))
            .transpose()
            .map(Option::flatten)
    } else {
        Ok(None)
    };
    let found = dossier.as_ref().ok().and_then(Option::as_ref);
    let health = Dirs::from_env().ok().filter(|_| initialized).map(|dirs| {
        let current = location
            .as_ref()
            .zip(found)
            .map(|((root, _), d)| (Path::new(root), d));
        doctor::startup_health(home, &dirs, launch, current, &executable)
    });
    let checkout = location.map(|(root, identity)| Checkout {
        github: github_url(&identity),
        hook: crate::check::hook_status(Path::new(&root)),
        dossier: found.map(|d| repo_facts(d, &root)),
        root,
        identity,
    });
    Facts {
        initialized,
        home: home.root.display().to_string(),
        checkout,
        health,
        dossier_error: dossier.err().map(|e| e.to_string()),
        executable,
        commands_doc,
    }
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

fn age(days: u64) -> String {
    match days {
        0 => "today".into(),
        1 => "yesterday".into(),
        n => format!("{n} days ago"),
    }
}

fn row(s: &mut String, label: &str, value: impl std::fmt::Display) {
    s.push_str(&format!("- {label:<11} {value}\n"));
}

fn alignment(s: &mut String, f: &Facts) {
    s.push_str("\nAlignment (local)\n");
    if let Some(c) = &f.checkout {
        let link = match &c.dossier {
            Some(repo) if repo.recorded => "checkout recorded in the dossier",
            Some(_) => "dossier found, checkout path not recorded",
            None if f.dossier_error.is_some() => "dossier could not be read",
            None => "checkout has no linked dossier",
        };
        row(s, "Link", link);
        row(s, "Pre-push", c.hook);
    }
    if let Some(h) = &f.health {
        if let Some(repo) = f.repo() {
            let instructions = if h.instruction_issues > 0 {
                format!(
                    "{} to review",
                    plural(h.instruction_issues, "finding", "findings")
                )
            } else if h.has_block {
                "managed AGENTS.md block and agent pointers aligned".into()
            } else if !repo.recorded {
                "run `sb add` to link this checkout before checking agent files".into()
            } else {
                "no managed AGENTS.md block (run `sb add` to enable managed agent files)".into()
            };
            row(s, "Agent files", instructions);
            if h.task_issues > 0 {
                row(
                    s,
                    "Task files",
                    plural(h.task_issues, "finding", "findings"),
                );
            }
        }
        let agents: Vec<_> = h
            .agents
            .iter()
            .map(|c| c.name.split(" (").next().unwrap_or(c.name))
            .collect();
        let mut mcp = if agents.is_empty() {
            "none registered".into()
        } else {
            agents.join(", ")
        };
        if h.mcp_issues > 0 {
            mcp.push_str(&format!(
                " ({})",
                plural(h.mcp_issues, "finding", "findings")
            ));
        }
        row(s, "MCP", format!("{mcp} [configuration]"));
    }
    let count = f.problems();
    let fixed = f.health.as_ref().map_or(0, |h| {
        h.findings
            .iter()
            .filter(|f| f.state == doctor::State::Fixed)
            .count()
    });
    let status = if count > 0 {
        format!("{} to review", plural(count, "finding", "findings"))
    } else if f.health.is_some() {
        "quick check passed".into()
    } else {
        "quick check unavailable".into()
    };
    let repaired = if fixed > 0 {
        format!("{fixed} repaired. ")
    } else {
        String::new()
    };
    let checked = f.health.as_ref().map_or_else(String::new, |h| {
        format!(" {} checked.", plural(h.checkouts, "checkout", "checkouts"))
    });
    row(
        s,
        "Health",
        format!("{repaired}{status}.{checked} Full scan: sb doctor"),
    );
    if let Some(error) = &f.dossier_error {
        s.push_str(&format!(
            "  - Review the dossier error with `sb doctor`: {error}\n"
        ));
    }
    if let Some(h) = &f.health {
        // Registrations that all point to the same older build are one problem, not many.
        const OLDER: &str = "points to an older SecondBrain build";
        const OLDER_PLURAL: &str = "point to an older SecondBrain build";
        let stale: Vec<&str> = h
            .findings
            .iter()
            .filter(|f| f.text.contains(OLDER))
            .filter_map(|f| f.scope.strip_prefix("mcp "))
            .collect();
        let grouped = stale.len() > 2;
        if grouped {
            s.push_str(&format!(
                "  - Action needed [mcp]: {} registrations {OLDER_PLURAL}. Update each and restart the client: sb mcp install --client <CLIENT> ({})\n",
                stale.len(),
                stale.join(", ")
            ));
        }
        for finding in h
            .findings
            .iter()
            .filter(|f| !(grouped && f.text.contains(OLDER) && f.scope.starts_with("mcp ")))
        {
            let label = match finding.state {
                doctor::State::Fixed => "Repaired",
                doctor::State::Fixable | doctor::State::Manual => "Action needed",
            };
            s.push_str(&format!(
                "  - {label} [{}]: {}\n",
                finding.scope, finding.text
            ));
        }
    }
}

fn short(title: &str) -> String {
    if title.chars().count() <= TITLE_WIDTH {
        return title.to_string();
    }
    let cut: String = title.chars().take(TITLE_WIDTH - 1).collect();
    format!("{}…", cut.trim_end())
}

fn state_label(line: &TaskLine) -> String {
    match line.kind {
        Kind::Ready => "ready".into(),
        Kind::NeedsInput => "needs input".into(),
        Kind::Doing => "in progress".into(),
        Kind::Blocked if line.waiting_on.is_empty() => "blocked".into(),
        Kind::Blocked => {
            let ids: Vec<String> = line.waiting_on.iter().map(|id| format!("#{id}")).collect();
            format!("waits for {}", ids.join(","))
        }
    }
}

fn tasks_section(s: &mut String, f: &Facts, repo: &Repo) {
    if f.health.as_ref().is_some_and(|h| h.task_issues > 0) {
        s.push_str("\nTasks\n- See the task file findings above.\n");
        return;
    }
    let mut counts = format!("{} open, {} ready", repo.open, repo.ready);
    if repo.needs_user > 0 {
        let verb = if repo.needs_user == 1 {
            "needs"
        } else {
            "need"
        };
        counts.push_str(&format!(", {} {verb} input", repo.needs_user));
    }
    s.push_str(&format!("\nTasks: {counts}\n"));
    if repo.lines.is_empty() {
        s.push_str("- No open tasks. Create one: sb task add \"Title\"\n");
        return;
    }
    for line in repo.lines.iter().take(TASK_ROWS) {
        let priority = line
            .priority
            .map_or_else(|| "  ".into(), |p| format!("P{p}"));
        s.push_str(&format!(
            "- {:<5} {:<14} {priority}  {}\n",
            format!("#{}", line.id),
            state_label(line),
            short(&line.title)
        ));
    }
    if repo.lines.len() > TASK_ROWS {
        s.push_str(&format!(
            "- +{} more: sb task list\n",
            repo.lines.len() - TASK_ROWS
        ));
    }
}

fn setup_steps(f: &Facts) -> Vec<(&'static str, &'static str)> {
    if !f.initialized {
        return vec![
            ("sb init", "Create the SecondBrain data folder"),
            (
                "sb guide onboarding",
                "Analyze a checkout and save its starting dossier",
            ),
        ];
    }
    let mut steps = Vec::new();
    if f.problems() > 0 {
        steps.push(("sb doctor", "Review local alignment findings"));
    }
    let Some(repo) = f.repo() else {
        if f.dossier_error.is_none() {
            if f.checkout.is_some() {
                steps.push(("sb add", "Link this checkout and its agent files"));
            } else {
                steps.push(("sb add <PATH>", "Link a Git checkout"));
            }
            steps.push((
                "sb guide onboarding",
                "Analyze the checkout and save its starting dossier",
            ));
        }
        return steps;
    };
    if !repo.recorded {
        steps.push((
            "sb add",
            "Record this checkout and link its agent files (--no-files to record only)",
        ));
    }
    if repo.context_age.is_none() {
        steps.push((
            "sb guide onboarding",
            "Analyze the checkout and save its starting dossier",
        ));
        steps.push((
            "sb context --set --if-empty",
            "Save the verified analysis as initial context (Markdown on standard input)",
        ));
    }
    steps
}

fn quick_start(s: &mut String, repo: &Repo) {
    const AGENT: &str = "--agent codex --model gpt-6.2-sol";
    let ready: Vec<&TaskLine> = repo
        .lines
        .iter()
        .filter(|l| l.kind == Kind::Ready)
        .collect();
    let mut body = String::new();
    if !ready.is_empty() {
        let request = match ready.len().min(3) {
            1 => "Run the next eligible task here".to_string(),
            n => format!("Run the next {n} eligible tasks here"),
        };
        body.push_str(&format!(
            "- Batch of ready tasks in the desktop app\n  - Ask the chat agent: \"{request}\"  (rules: sb guide chat)\n"
        ));
        body.push_str(&format!(
            "- Unattended in the CLI (nobody at the keyboard)\n  - Preview the queue: sb run --dry-run\n  - Run every ready task: sb run --all {AGENT}\n"
        ));
    }
    if let Some((id, true)) = repo.prepare {
        body.push_str(&format!(
            "- Make \"needs input\" tasks unattended\n  - CLI: sb task prepare {id}  (interview; or sb task set {id} --needs-user false)\n  - Desktop app: ask the chat agent \"Prepare task #{id} for unattended work: interview me\"\n  - All of them: sb prepare, or ask the chat agent \"Prepare all tasks that need input\"\n"
        ));
    }
    if let Some(first) = ready.first() {
        body.push_str(&format!(
            "- One task at a time\n  - CLI: sb run --task {} {AGENT}\n  - Desktop app: ask the chat agent \"Start task #{}\"\n",
            first.id, first.id
        ));
        if let Some(next) = ready.get(1) {
            body.push_str(&format!(
                "  - Next in line: #{} {}\n",
                next.id,
                short(&next.title)
            ));
        }
    }
    if body.is_empty() {
        body.push_str(
            "- Nothing to run yet. Create a task: sb task add \"Title\" --accept \"cargo test\"\n",
        );
    }
    s.push_str("\nQuick start\n");
    s.push_str(&body);
}

fn tips(s: &mut String, f: &Facts) {
    let mut tips: Vec<String> = Vec::new();
    if let Some(repo) = f.repo() {
        if let Some(id) = repo.unchecked.first() {
            tips.push(format!(
                "Give ready tasks an acceptance command so unattended runs verify their work: sb task set {id} --accept \"cargo test\""
            ));
        }
        if f.health.as_ref().is_some_and(|h| h.agents.is_empty()) {
            tips.push("No agent has the MCP server registered, so desktop chats cannot see the queue: sb mcp install".into());
        }
        if let Some(days) = repo.context_age.filter(|d| *d > 14) {
            tips.push(format!(
                "The context is {days} days old. Refresh it: sb context --set"
            ));
        }
    }
    if f.checkout
        .as_ref()
        .is_some_and(|c| c.hook == "optional hook not installed")
    {
        tips.push("Scan pushes automatically: sb check --install-hook".into());
    }
    if tips.is_empty() {
        return;
    }
    s.push_str("\nTips\n");
    for tip in tips.iter().take(3) {
        s.push_str(&format!("- {tip}\n"));
    }
}

fn render(f: &Facts, directive_version: &str) -> String {
    let mut s = format!(
        "SecondBrain {}\nPrivate context, decisions and tasks for your coding agents.\n\nStatus\n",
        env!("CARGO_PKG_VERSION")
    );
    let home = if f.initialized {
        f.home.clone()
    } else {
        format!("{} (not set up)", f.home)
    };
    row(&mut s, "Home", home);
    s.push_str(&f.executable.text());
    row(&mut s, "Directive", directive_version);
    if let Some(c) = &f.checkout {
        row(&mut s, "Path", &c.root);
        if let Some(url) = &c.github {
            row(&mut s, "GitHub", url);
        }
        let state = if c.dossier.is_some() {
            "linked"
        } else if f.dossier_error.is_some() {
            "dossier unavailable"
        } else {
            "none linked here"
        };
        row(&mut s, "Repository", format!("{} ({state})", c.identity));
        if let Some(r) = &c.dossier {
            let context = r
                .context_age
                .map_or_else(|| "empty".into(), |d| format!("updated {}", age(d)));
            row(&mut s, "Context", context);
        }
        alignment(&mut s, f);
    } else {
        row(&mut s, "Repository", "outside a Git checkout");
        if f.initialized {
            alignment(&mut s, f);
        }
    }
    if let Some(repo) = f.repo() {
        tasks_section(&mut s, f, repo);
    }
    let steps = setup_steps(f);
    if !steps.is_empty() {
        s.push_str("\nNext steps\n");
        for (command, purpose) in steps {
            s.push_str(&format!("- {command:<28} {purpose}\n"));
        }
    }
    if let Some(repo) = f.repo() {
        quick_start(&mut s, repo);
    }
    tips(&mut s, f);
    s.push_str("\nMenus (commands, parameters and examples)\n");
    for group in GROUPS {
        s.push_str(&format!("- {:<18} {}\n", group.route(), group.description));
    }
    s.push_str("\nReference\n");
    s.push_str(&format!(
        "- All commands and parameters: {}/blob/master/COMMANDS.md\n",
        env!("CARGO_PKG_REPOSITORY").trim_end_matches('/')
    ));
    if let Some(path) = &f.commands_doc {
        s.push_str(&format!("- Local copy: {path}\n"));
    }
    s.push_str("- sb commands                 List every command with its parameters\n- sb guide                    Explain commands and workflows\n");
    s.push_str("\nIn chat, report the status, alignment, findings, next steps, commands and parameter descriptions in bullet lists in the first reply.\n");
    s.push_str("Put an example beside each command and parameter.\n");
    s
}

pub fn text(home: &Home, cwd: &Path, launch: &Launch) -> String {
    let body = crate::block::body(&home.rules());
    let version = crate::block::directive_version(&body).unwrap_or("unknown");
    render(&gather(home, cwd, launch), version)
}

#[cfg(test)]
mod tests {
    use super::github_url;

    #[test]
    fn github_links_require_a_normalized_owner_and_repository() {
        assert_eq!(
            github_url("github.com/a/b").as_deref(),
            Some("https://github.com/a/b")
        );
        for identity in [
            "local/project",
            "github.com/a/b?extra",
            "github.com/a/b/c",
            "github.com/a/..",
        ] {
            assert_eq!(github_url(identity), None);
        }
    }
}
