//! `sb run`: works through a repository's open tasks unattended, one fresh agent process per task.
//!
//! Safety model: the run happens on its own `sb/run-*` branch created from a clean tree;
//! agents may edit files and run only the programs a task names (its acceptance command, the
//! handoff **Commands** and `--allow-cmd`) in Claude Code and Gemini CLI, or inside the Codex
//! sandbox; they never commit or push;
//! `sb` commits each task's changes locally and never pushes. A task whose programs are not
//! on the PATH is skipped before it starts. The person reviews and merges the branch.

mod process;

use crate::date;
use crate::ops;
use crate::store::{Dossier, Home, write_atomic};
use crate::task::{Status, Task};
use anyhow::{Context as _, Result, anyhow, bail};
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const BRANCH_PREFIX: &str = "sb/run-";
const RESULT_MARKER: &str = "SB-RESULT:";
const QUOTA_HINTS: &[&str] = &[
    "usage limit",
    "hit your limit",
    "reached your limit",
    "out of usage",
    "quota",
    "resource_exhausted",
];

pub struct RunOptions {
    pub agent: Option<String>,
    pub agent_cmd: Option<String>,
    pub task: Option<u32>,
    pub limit: Option<usize>,
    /// Run every ready task (instead of `limit`).
    pub all: bool,
    /// Model and effort for a known agent; asked for in a terminal, required without one.
    pub model: Option<String>,
    pub effort: Option<String>,
    pub timeout_minutes: u64,
    /// Extra programs Claude Code and Gemini CLI may run without asking (`--allow-cmd`).
    pub allow_cmd: Vec<String>,
    pub dry_run: bool,
}

/// A program and its fixed arguments; the prompt always goes to standard input.
#[derive(Clone, Debug)]
pub struct Agent {
    pub name: String,
    pub program: PathBuf,
    pub args: Vec<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl Agent {
    /// `claude (opus, high)`: the agent with the model and effort it was started with.
    pub fn label(&self) -> String {
        match (&self.model, &self.effort) {
            (Some(m), Some(e)) => format!("{} ({m}, {e})", self.name),
            (Some(m), None) => format!("{} ({m})", self.name),
            _ => self.name.clone(),
        }
    }
}

/// The models and effort levels sb offers for each known agent. Edit here when a provider
/// adds one; a run refuses a model that is not listed.
pub fn provider_choices(agent: &str) -> (&'static [&'static str], &'static [&'static str]) {
    match agent {
        "claude" => (
            &[
                "opus",
                "sonnet",
                "haiku",
                "claude-opus-5-5",
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
                "claude-fable-5-2",
            ],
            &["low", "medium", "high", "xhigh", "max"],
        ),
        "codex" => (
            &[
                "gpt-6.2-sol",
                "gpt-6.2-astra",
                "gpt-6.1-terra",
                "gpt-6.1-sol",
                "gpt-6-astra",
                "gpt-6-sol",
                "gpt-6-luna",
                "gpt-5.6-sol",
                "gpt-5.6-terra",
                "gpt-5.6-luna",
            ],
            &["low", "medium", "high", "xhigh", "max"],
        ),
        "gemini" => (&["gemini-2.5-pro", "gemini-2.5-flash"], &[]),
        _ => (&[], &[]),
    }
}

/// Puts the chosen model and effort on the agent's command line.
fn with_choices(mut agent: Agent, model: &str, effort: Option<&str>) -> Agent {
    let mut extra: Vec<String> = Vec::new();
    match agent.name.as_str() {
        "claude" => {
            extra.extend(["--model".into(), model.into()]);
            if let Some(e) = effort {
                extra.extend(["--effort".into(), e.into()]);
            }
            agent.args.extend(extra);
        }
        "codex" => {
            extra.extend(["-m".into(), model.into()]);
            if let Some(e) = effort {
                extra.extend(["-c".into(), format!("model_reasoning_effort=\"{e}\"")]);
            }
            // After the `exec` word, before the sandbox flags.
            let at = agent
                .args
                .iter()
                .position(|a| a == "exec")
                .map_or(0, |i| i + 1);
            for (i, a) in extra.into_iter().enumerate() {
                agent.args.insert(at + i, a);
            }
        }
        _ => {
            for (i, a) in ["-m".to_string(), model.to_string()]
                .into_iter()
                .enumerate()
            {
                agent.args.insert(i, a);
            }
        }
    }
    agent.model = Some(model.into());
    agent.effort = effort.map(str::to_string);
    agent
}

/// What the person (or the flags) decided before the queue starts.
#[derive(Debug, PartialEq)]
pub struct Choices {
    pub model: String,
    pub effort: Option<String>,
    /// How many tasks to run at most; `None` is every ready task.
    pub count: Option<usize>,
}

/// Decides model, effort and number of tasks for a known agent. In a terminal missing choices
/// are asked through `ask(question, options) -> answer`; without one they must be flags.
pub fn resolve_choices(
    agent: &str,
    opts: &RunOptions,
    ready: usize,
    interactive: bool,
    ask: &mut dyn FnMut(&str, &[String]) -> Result<String>,
) -> Result<Choices> {
    let (models, efforts) = provider_choices(agent);
    let list = |v: &[&str]| v.join(", ");

    let model = match &opts.model {
        Some(m) if models.contains(&m.as_str()) => m.clone(),
        Some(m) => bail!(
            "model '{m}' is not one sb knows for {agent} ({})",
            list(models)
        ),
        None if interactive => {
            let options: Vec<String> = models.iter().map(|s| s.to_string()).collect();
            ask(&format!("Which {agent} model?"), &options)?
        }
        None => bail!("choose the model with --model ({})", list(models)),
    };

    let effort = match &opts.effort {
        Some(_) if efforts.is_empty() => bail!("{agent} has no effort setting; leave --effort out"),
        Some(e) if efforts.contains(&e.as_str()) => Some(e.clone()),
        Some(e) => bail!(
            "effort '{e}' is not one sb knows for {agent} ({})",
            list(efforts)
        ),
        None if interactive && !efforts.is_empty() => {
            let mut options: Vec<String> = efforts.iter().map(|s| s.to_string()).collect();
            options.push("default".into());
            let answer = ask(&format!("Which {agent} effort?"), &options)?;
            (answer != "default").then_some(answer)
        }
        None => None,
    };

    let count = if opts.task.is_some() {
        Some(1)
    } else if opts.all {
        None
    } else if let Some(n) = opts.limit {
        Some(n)
    } else if interactive {
        let mut options: Vec<String> = (1..=ready.min(5)).map(|n| n.to_string()).collect();
        if ready > 5 {
            options.push(ready.to_string());
        }
        options.push("all".into());
        let answer = ask(&format!("How many of the {ready} ready tasks?"), &options)?;
        if answer == "all" {
            None
        } else {
            Some(
                answer
                    .parse::<usize>()
                    .map_err(|_| anyhow!("'{answer}' is not a number"))?,
            )
        }
    } else {
        bail!("say how many tasks to run with --limit N or --all ({ready} are ready)");
    };
    Ok(Choices {
        model,
        effort,
        count,
    })
}

/// A numbered question on the terminal; the answer is an option, or typed text.
fn ask_choice(question: &str, options: &[String]) -> Result<String> {
    eprintln!("{question}");
    for (i, o) in options.iter().enumerate() {
        eprintln!("  {}. {o}", i + 1);
    }
    eprint!("Number: ");
    std::io::stderr().flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let n: usize = line.trim().parse().map_err(|_| anyhow!("no choice made"))?;
    options
        .get(n.wrapping_sub(1))
        .cloned()
        .ok_or_else(|| anyhow!("no choice number {n}"))
}

#[derive(Debug, PartialEq)]
pub enum Outcome {
    Done,
    Blocked(String),
    NeedsUser(String),
    Failed(String),
}

pub const KNOWN_AGENTS: &[&str] = &["claude", "codex", "gemini"];

/// Fixed, edits-only arguments for each supported agent.
pub fn known_agent(name: &str) -> Result<Agent> {
    let args: &[&str] = match name {
        "claude" => &["-p", "--permission-mode", "acceptEdits"],
        "codex" => &[
            "exec",
            "--sandbox",
            "workspace-write",
            "--skip-git-repo-check",
            "-",
        ],
        "gemini" => &[
            "--approval-mode",
            "auto_edit",
            "-p",
            "Carry out the instructions above.",
        ],
        other => bail!("unknown agent '{other}' (use claude, codex, gemini or --agent-cmd)"),
    };
    let program = which(name).ok_or_else(|| anyhow!("{name} is not on the PATH"))?;
    Ok(Agent {
        name: name.to_string(),
        program,
        args: args.iter().map(|s| s.to_string()).collect(),
        model: None,
        effort: None,
    })
}

/// A custom agent: `program arg ...`, double quotes group words.
pub fn custom_agent(command: &str) -> Result<Agent> {
    let words = split_command(command);
    let (first, rest) = words
        .split_first()
        .ok_or_else(|| anyhow!("--agent-cmd is empty"))?;
    let program = if Path::new(first).is_file() {
        PathBuf::from(first)
    } else {
        which(first).ok_or_else(|| anyhow!("{first} is not on the PATH"))?
    };
    Ok(Agent {
        name: first.to_string(),
        program,
        args: rest.to_vec(),
        model: None,
        effort: None,
    })
}

/// Finds a program on the PATH (with the Windows executable extensions).
pub fn which(name: &str) -> Option<PathBuf> {
    let exts: &[&str] = if cfg!(windows) {
        &[".exe", ".cmd", ".bat", ".com"]
    } else {
        &[""]
    };
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for ext in exts {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn split_command(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut has_word = false;
    for c in command.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                has_word = true;
            }
            c if c.is_whitespace() && !quoted => {
                if has_word {
                    words.push(std::mem::take(&mut current));
                    has_word = false;
                }
            }
            c => {
                current.push(c);
                has_word = true;
            }
        }
    }
    if has_word {
        words.push(current);
    }
    words
}

/// Tasks an unattended run may take now: open, `todo` (or an expired claim), not waiting on a
/// person, every blocker done, not held by someone else. Best first.
pub fn runnable(d: &Dossier, only: Option<u32>, limit: Option<usize>) -> Result<Vec<Task>> {
    if let Some(id) = only {
        let all = d.tasks()?;
        crate::store::validate_graph(&all)?;
        let now = date::now_secs();
        let t = all
            .iter()
            .find(|t| t.id == id)
            .cloned()
            .ok_or_else(|| anyhow!("no task #{id}"))?;
        if t.needs_user {
            bail!("task #{id} needs you, so it cannot run unattended");
        }
        if t.status != Status::Todo && t.status != Status::Doing {
            bail!("task #{id} is {}, not todo", t.status);
        }
        if t.is_claimed(now) {
            bail!(
                "task #{id} is held by {}",
                t.claimed_by.as_deref().unwrap_or("someone")
            );
        }
        if !crate::store::is_ready(&t, &all, now) {
            bail!("task #{id} is waiting for its blockers");
        }
        return Ok(vec![t]);
    }
    let mut tasks = d.ready_tasks()?;
    if let Some(n) = limit {
        tasks.truncate(n);
    }
    Ok(tasks)
}

/// Runs a task's acceptance command in the repository: `(passed, last output line)`.
fn check_accept(root: &Path, command: &str, timeout: Duration) -> Result<(bool, String)> {
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", command]);
        c
    } else {
        let mut c = Command::new("sh");
        c.args(["-c", command]);
        c
    };
    cmd.current_dir(root);
    let capture = process::capture(cmd, None, timeout)
        .with_context(|| format!("running the acceptance command `{command}`"))?;
    let mut text = String::from_utf8_lossy(&capture.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&capture.stderr));
    let last = text
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim()
        .to_string();
    match capture.status {
        Some(st) if st.success() => Ok((true, last)),
        Some(st) => Ok((
            false,
            format!(
                "exit {}: {last}",
                st.code().map_or("none".into(), |c| c.to_string())
            ),
        )),
        None => Ok((false, "timed out".into())),
    }
}

/// Shell builtins that need no program on the PATH.
const BUILTINS: &[&str] = &["cd", "echo", "set", "exit", "true", "false", "test"];

/// The program a command word names: no folder, no `.exe`, and only plain characters so it is
/// safe inside a permission pattern.
fn program_name(word: &str) -> Option<String> {
    let base = word.rsplit(['/', '\\']).next()?;
    let base = base.strip_suffix(".exe").unwrap_or(base);
    let plain = base
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    (!base.is_empty() && plain && !BUILTINS.contains(&base)).then(|| base.to_string())
}

/// The programs a command line runs, such as `cargo fmt && cargo test`.
fn programs_in(command: &str) -> Vec<String> {
    command
        .split(['&', '|', ';', '\n'])
        .filter_map(|part| split_command(part).into_iter().next())
        .filter_map(|word| program_name(&word))
        .collect()
}

/// The programs listed under **Commands** in a task's handoff (comma separated).
fn handoff_commands(body: &str) -> Vec<String> {
    let Some((_, rest)) = body.split_once("**Commands**\n") else {
        return Vec::new();
    };
    rest.lines()
        .next()
        .unwrap_or("")
        .split([',', ';'])
        .filter_map(|entry| split_command(entry).into_iter().next())
        .filter_map(|word| program_name(&word))
        .collect()
}

/// What an agent may run for one task: the acceptance command, the handoff **Commands** and
/// `--allow-cmd`, each program once.
pub fn allowed_programs(t: &Task, extra: &[String]) -> Vec<String> {
    let mut all = Vec::new();
    let named = t
        .accept
        .iter()
        .flat_map(|a| programs_in(a))
        .chain(handoff_commands(&t.body))
        .chain(extra.iter().filter_map(|e| program_name(e)));
    for p in named {
        if !all.contains(&p) {
            all.push(p);
        }
    }
    all
}

/// Programs that are not on the PATH: a task needing them cannot be verified, so it is not started.
fn missing_programs(programs: &[String]) -> Vec<String> {
    programs
        .iter()
        .filter(|p| which(p).is_none())
        .cloned()
        .collect()
}

/// What an agent may do in the shell during one task.
#[derive(Clone, Debug, PartialEq)]
pub enum Shell {
    /// Only these programs; everything else is denied.
    Listed(Vec<String>),
    /// Codex: commands run inside its workspace-write sandbox without approval.
    Sandboxed,
    /// No shell commands.
    Denied,
}

/// Pre-approves the shell programs a task needs, in each known agent's own way: Claude Code
/// `--allowedTools`, Gemini CLI `--allowed-tools`, Codex through its sandbox. A custom agent
/// command keeps its own arguments and gets no shell.
#[cfg(test)]
fn with_allowed(agent: Agent, programs: &[String], custom: bool) -> (Agent, Shell) {
    with_allowed_policy(agent, programs, custom, None)
}

/// Gemini CLI builds from this one deprecate `--allowed-tools` in favor of the Policy Engine.
const GEMINI_POLICY_FROM: (u64, u64) = (0, 68);

/// Reads `major.minor` from the first version-like token of `gemini --version` output.
fn parse_version(text: &str) -> Option<(u64, u64)> {
    let token = text.split_whitespace().find(|w| {
        w.trim_start_matches('v')
            .starts_with(|c: char| c.is_ascii_digit())
    })?;
    let mut parts = token.trim_start_matches('v').split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts
        .next()?
        .split(|c: char| !c.is_ascii_digit())
        .next()?
        .parse()
        .ok()?;
    Some((major, minor))
}

/// Whether this Gemini CLI understands `--policy`; an unknown version keeps `--allowed-tools`.
fn gemini_supports_policy(agent: &Agent) -> bool {
    let Ok(out) = Command::new(&agent.program).arg("--version").output() else {
        return false;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    parse_version(&text).is_some_and(|v| v >= GEMINI_POLICY_FROM)
}

/// A Gemini Policy Engine file that allows exactly these shell programs.
fn gemini_policy(programs: &[String]) -> String {
    let mut out = String::new();
    for p in programs {
        out.push_str(&format!(
            "[[rule]]\ntoolName = \"run_shell_command\"\ncommandPrefix = \"{p}\"\ndecision = \"allow\"\npriority = 100\n\n"
        ));
    }
    out
}

/// Like `with_allowed`; a Gemini agent given a policy file path gets `--policy` instead of
/// `--allowed-tools`.
fn with_allowed_policy(
    mut agent: Agent,
    programs: &[String],
    custom: bool,
    policy: Option<&Path>,
) -> (Agent, Shell) {
    if custom {
        return (agent, Shell::Denied);
    }
    let listed = || Shell::Listed(programs.to_vec());
    match agent.name.as_str() {
        "claude" if !programs.is_empty() => {
            let tools: Vec<String> = programs.iter().map(|p| format!("Bash({p}:*)")).collect();
            agent.args.push("--allowedTools".into());
            agent.args.push(tools.join(","));
            (agent, listed())
        }
        "gemini" if !programs.is_empty() => {
            let mut args = Vec::new();
            if let Some(path) = policy {
                args.push("--policy".to_string());
                args.push(path.to_string_lossy().into_owned());
            } else {
                for p in programs {
                    args.push("--allowed-tools".to_string());
                    args.push(format!("run_shell_command({p})"));
                }
            }
            args.append(&mut agent.args);
            agent.args = args;
            (agent, listed())
        }
        "codex" => (agent, Shell::Sandboxed),
        _ => (agent, Shell::Denied),
    }
}

pub fn prompt(d: &Dossier, root: &str, branch: &str, t: &Task, shell: &Shell) -> String {
    let approvals = if t.body.contains("**Authorizations**") {
        "- Approvals were collected before the run and are recorded under Authorizations in the task. Do not ask for more and do not act beyond them.".to_string()
    } else {
        "- No approvals were recorded for this task: do nothing that needs one (installs, network access, deleting data, accounts, external services).".to_string()
    };
    let commands = match shell {
        Shell::Denied => "- Shell commands are denied in this run and nobody can approve them: do not retry one."
            .to_string(),
        Shell::Sandboxed => "- Shell commands run in a sandbox that only writes inside this repository and has no approvals: do not try to leave it.".to_string(),
        Shell::Listed(programs) => format!(
            "- You may run these programs without asking: {}. Every other shell command is denied and nobody can approve it: do not retry one.",
            programs.join(", ")
        ),
    };
    let verify = match &t.accept {
        Some(cmd) => format!(
            "- sb runs `{cmd}` itself after you finish and blocks the task if it fails. A check you cannot run is not a reason to stop: finish the work and report done."
        ),
        None => "- sb runs no check after you. If you could not compile or test the change, report needs-user and say what was not verified.".to_string(),
    };
    let context = d.context();
    let context = if context.trim().is_empty() {
        "(none recorded)".to_string()
    } else {
        context.trim().to_string()
    };
    let body = if t.body.trim().is_empty() {
        "(no description)".to_string()
    } else {
        t.body.trim().to_string()
    };
    let rules = d.rules();
    let rules = if rules.trim().is_empty() {
        String::new()
    } else {
        format!("# Repository rules\n\n{}\n\n", rules.trim())
    };
    format!(
        "You are working unattended on one task in the Git repository at {root} (branch {branch}). \
Nobody can answer questions during this run.\n\n\
# Task #{id}: {title}\n\n{body}\n\n\
# Project context\n\n{context}\n\n\
{rules}\
# Rules\n\n\
- Work only on this task, with the smallest change that completes it; follow the repository's AGENTS.md.\n\
- Do not commit, push, tag, switch branches, rewrite history or delete branches. Leave your changes in the working tree: sb commits them after you finish.\n\
- Do not change files outside this repository.\n\
{approvals}\n\
{commands}\n\
{verify}\n\
- If the task needs a person (a decision, credentials, access, a manual check, an approval that was not granted), stop and say what is needed.\n\
- Use blocked only when another task or a system you cannot reach is in the way. Work that is written but not verified is needs-user, never blocked.\n\
- End your final message with exactly one of these lines:\n\
{m} done\n\
{m} blocked <the reason>\n\
{m} needs-user <what the person must do or decide>\n",
        id = t.id,
        title = t.title,
        m = RESULT_MARKER,
    )
}

/// The last `SB-RESULT:` line of the agent's output.
pub fn parse_outcome(output: &str) -> Option<Outcome> {
    let line = output
        .lines()
        .rev()
        .map(|l| l.trim().trim_matches(['*', '`']).trim())
        .find(|l| l.starts_with(RESULT_MARKER))?;
    let rest = line[RESULT_MARKER.len()..].trim();
    let (word, reason) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
    let reason = reason.trim().to_string();
    match word.to_ascii_lowercase().as_str() {
        "done" => Some(Outcome::Done),
        "blocked" => Some(Outcome::Blocked(if reason.is_empty() {
            "no reason given".into()
        } else {
            reason
        })),
        "needs-user" | "needs_user" => Some(Outcome::NeedsUser(if reason.is_empty() {
            "no detail given".into()
        } else {
            reason
        })),
        _ => None,
    }
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .with_context(|| format!("running git {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn lock_worktree(root: &Path) -> Result<std::fs::File> {
    let path = git(root, &["rev-parse", "--git-path", "secondbrain-run.lock"])?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join(path))
        .context("opening the SecondBrain worktree lock")?;
    match lock.try_lock() {
        Ok(()) => Ok(lock),
        Err(std::fs::TryLockError::WouldBlock) => {
            bail!("another `sb run` already owns this Git worktree")
        }
        Err(std::fs::TryLockError::Error(error)) => Err(error).context("locking the Git worktree"),
    }
}

fn ask_agent() -> Result<Agent> {
    if !std::io::stdin().is_terminal() {
        bail!("choose the agent with --agent claude|codex|gemini or --agent-cmd \"...\"");
    }
    let found: Vec<&str> = KNOWN_AGENTS
        .iter()
        .copied()
        .filter(|n| which(n).is_some())
        .collect();
    if found.is_empty() {
        bail!("none of claude, codex or gemini is on the PATH; install one or use --agent-cmd");
    }
    eprintln!("Which agent should work on the tasks?");
    for (i, n) in found.iter().enumerate() {
        eprintln!("  {}. {n}", i + 1);
    }
    eprint!("Number: ");
    std::io::stderr().flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let choice: usize = line
        .trim()
        .parse()
        .map_err(|_| anyhow!("no agent chosen"))?;
    let name = found
        .get(choice.wrapping_sub(1))
        .ok_or_else(|| anyhow!("no agent number {choice}"))?;
    known_agent(name)
}

struct Execution {
    output: String,
    exit: Option<i32>,
    timed_out: bool,
}

fn execute(agent: &Agent, root: &Path, input: &str, timeout: Duration) -> Result<Execution> {
    let mut command = Command::new(&agent.program);
    command.args(&agent.args).current_dir(root);
    let capture = process::capture(command, Some(input), timeout)
        .with_context(|| format!("starting {}", agent.program.display()))?;
    let mut output = String::from_utf8_lossy(&capture.stdout).into_owned();
    if !capture.stderr.is_empty() {
        output.push_str("\n--- stderr ---\n");
        output.push_str(&String::from_utf8_lossy(&capture.stderr));
    }
    Ok(Execution {
        output,
        exit: capture.status.and_then(|status| status.code()),
        timed_out: capture.status.is_none(),
    })
}

/// Runs the selected tasks; `progress` receives one line per step as it happens.
pub fn run(
    home: &Home,
    cwd: &Path,
    opts: RunOptions,
    progress: &mut dyn FnMut(&str),
) -> Result<String> {
    let d = home.resolve_repo(None, cwd)?;
    let (root, _) = ops::checkout(cwd)?;
    let root_path = PathBuf::from(&root);
    let tasks = runnable(&d, opts.task, None)?;
    if tasks.is_empty() {
        return Ok(
            "No task can run unattended (todo, unblocked, free and not waiting on you). Nothing to do.\n"
                .into(),
        );
    }
    if opts.dry_run {
        let mut s = format!(
            "{} task(s) would run now, in this order (tasks they unblock follow):\n",
            tasks.len()
        );
        s.push_str(&ops::task_list_text(&tasks));
        return Ok(s);
    }

    let mut agent = match (&opts.agent_cmd, &opts.agent) {
        (Some(cmd), _) => custom_agent(cmd)?,
        (None, Some(name)) => known_agent(&name.to_lowercase())?,
        (None, None) => ask_agent()?,
    };
    // The queue only starts once the model, the effort and the number of tasks are settled.
    // A custom agent command owns its own model, so only the limit applies to it.
    let mut limit = if opts.all { None } else { opts.limit };
    if opts.agent_cmd.is_none() {
        let interactive = std::io::stdin().is_terminal();
        let c = resolve_choices(
            &agent.name,
            &opts,
            tasks.len(),
            interactive,
            &mut ask_choice,
        )?;
        agent = with_choices(agent, &c.model, c.effort.as_deref());
        limit = c.count;
        progress(&format!(
            "Starting with {}, {}",
            agent.label(),
            match limit {
                Some(n) => format!("up to {n} of {} ready task(s)", tasks.len()),
                None => format!("all {} ready task(s)", tasks.len()),
            }
        ));
    }
    let _worktree = lock_worktree(&root_path)?;
    if !git(&root_path, &["status", "--porcelain"])?.is_empty() {
        bail!("the working tree has uncommitted changes; commit or stash them before `sb run`");
    }
    let current = git(&root_path, &["rev-parse", "--abbrev-ref", "HEAD"])?;
    if current == "HEAD" {
        bail!("HEAD is detached; check out a branch before `sb run`");
    }
    let branch = if current.starts_with(BRANCH_PREFIX) {
        current.clone()
    } else {
        let name = format!("{BRANCH_PREFIX}{}", date::stamp());
        git(&root_path, &["switch", "-q", "-c", &name])?;
        progress(&format!("Created branch {name} from {current}"));
        name
    };
    let timeout = Duration::from_secs(opts.timeout_minutes.max(1).saturating_mul(60));
    let logs = d.dir.join("runs");
    let mut summary = Vec::new();

    let max = limit.unwrap_or(usize::MAX);
    let mut attempted = Vec::new();
    loop {
        if attempted.len() >= max {
            break;
        }
        // The queue is recomputed after every task: finishing one can unblock the next.
        let next = if opts.task.is_some() {
            tasks.iter().find(|t| !attempted.contains(&t.key)).cloned()
        } else {
            d.ready_tasks()?
                .into_iter()
                .find(|t| !attempted.contains(&t.key))
        };
        let Some(task) = next else {
            break;
        };
        attempted.push(task.key.clone());
        let programs = allowed_programs(&task, &opts.allow_cmd);
        let custom = opts.agent_cmd.is_some();
        let mut policy = None;
        if !custom
            && agent.name == "gemini"
            && !programs.is_empty()
            && gemini_supports_policy(&agent)
        {
            let path = d.dir.join("policies").join(format!("{}.toml", task.id));
            write_atomic(&path, &gemini_policy(&programs))?;
            policy = Some(path);
        }
        let (task_agent, shell) =
            with_allowed_policy(agent.clone(), &programs, custom, policy.as_deref());
        let absent = missing_programs(&programs);
        if !absent.is_empty() {
            let why = format!(
                "preflight: {} not on the PATH, so the task cannot be built or verified here",
                absent.join(", ")
            );
            progress(&format!("#{} {} skipped: {why}", task.id, task.title));
            summary.push(format!("#{} skipped: {why}", task.id));
            continue;
        }
        progress(&format!("#{} {} ({})", task.id, task.title, agent.label()));
        let lease = opts
            .timeout_minutes
            .max(1)
            .saturating_mul(2)
            .saturating_add(5);
        let owner = format!("sb run ({}) {}", agent.name, crate::store::unique_token());
        let t = match d.claim_selected_task(&task, &owner, lease) {
            Ok(t) => t,
            Err(e) => {
                progress(&format!("  skipped: {e}"));
                summary.push(format!("#{} skipped: {e}", task.id));
                continue;
            }
        };

        let input = prompt(&d, &root, &branch, &t, &shell);
        let exec = execute(&task_agent, &root_path, &input, timeout)?;
        let log = logs.join(format!("{}-{}.log", date::stamp(), t.id));
        write_atomic(
            &log,
            &format!("# prompt\n\n{input}\n# output\n\n{}\n", exec.output),
        )?;

        let mut outcome = if exec.timed_out {
            Outcome::Failed(format!("stopped after {} minutes", opts.timeout_minutes))
        } else {
            match (parse_outcome(&exec.output), exec.exit) {
                (Some(o), Some(0)) => o,
                (_, code) if code != Some(0) => Outcome::Failed(format!(
                    "the agent exited with code {}",
                    code.map_or("none".into(), |c| c.to_string())
                )),
                _ => Outcome::Failed("the agent gave no SB-RESULT line".into()),
            }
        };
        let quota = matches!(outcome, Outcome::Failed(_)) && {
            let lower = exec.output.to_lowercase();
            QUOTA_HINTS.iter().any(|h| lower.contains(h))
        };

        let now_branch = git(&root_path, &["rev-parse", "--abbrev-ref", "HEAD"])?;
        if now_branch != branch {
            d.finish_owned_claim(&t, |task| {
                task.status = Status::Blocked;
                task.body = note(
                    &task.body,
                    &agent.name,
                    &format!("the agent switched to branch {now_branch}; run stopped"),
                    &log,
                );
                Ok(())
            })?;
            bail!(
                "the agent switched from {branch} to {now_branch}; the run stopped so nothing is committed on the wrong branch"
            );
        }

        if outcome == Outcome::Done
            && let Some(cmd) = t.accept.clone()
        {
            progress(&format!("  checking acceptance: {cmd}"));
            let (ok, detail) = check_accept(&root_path, &cmd, timeout)?;
            if !ok {
                outcome = Outcome::Blocked(format!("acceptance check failed ({detail})"));
            }
        }
        let (status, needs_user, label) = match &outcome {
            Outcome::Done => (Status::Done, false, "done".to_string()),
            Outcome::Blocked(r) => (Status::Blocked, false, format!("blocked: {r}")),
            Outcome::NeedsUser(r) => (Status::Todo, true, format!("needs you: {r}")),
            Outcome::Failed(r) => (Status::Blocked, false, format!("failed: {r}")),
        };
        let detail = d.finish_owned_claim(&t, |task| {
        if git(&root_path, &["rev-parse", "--abbrev-ref", "HEAD"])? != branch {
            bail!("the working branch changed during acceptance; the run stopped before committing");
        }
        let changed = !git(&root_path, &["status", "--porcelain"])?.is_empty();
        let commit = if changed {
            git(&root_path, &["add", "-A"])?;
            let subject = if outcome == Outcome::Done {
                format!("Complete sb task #{}", task.id)
            } else {
                format!("Not done: sb task #{}", task.id)
            };
            let body = format!("sb run with {}: {label}", agent.label());
            git(&root_path, &["commit", "-q", "-m", &subject, "-m", &body])?;
            Some(git(&root_path, &["rev-parse", "--short", "HEAD"])?)
        } else {
            None
        };

        task.status = status;
        task.needs_user |= needs_user;
        let detail = match &commit {
            Some(c) => format!("{label}; commit {c} on {branch}"),
            None => format!("{label}; no file changed"),
        };
        task.body = note(&task.body, &agent.name, &detail, &log);
        Ok(detail)
        })?;

        let line = format!("#{} {}", t.id, detail);
        progress(&format!("  {detail}"));
        summary.push(line);
        if quota {
            summary.push("Stopped: the agent's output looks like a usage limit.".into());
            break;
        }
    }

    let mut s = format!("\nRun finished on branch {branch} (nothing pushed):\n");
    for l in &summary {
        s.push_str(&format!("- {l}\n"));
    }
    s.push_str(&format!(
        "Review with `git log {current}..{branch}`, then merge or delete the branch. Logs: {}\n",
        logs.display()
    ));
    Ok(s)
}

fn note(body: &str, agent: &str, detail: &str, log: &Path) -> String {
    let entry = format!(
        "## sb run {} ({agent})\n\n{detail}. Log: {}",
        date::today(),
        log.display()
    );
    if body.trim().is_empty() {
        entry
    } else {
        format!("{}\n\n{entry}", body.trim_end())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outcome_lines() {
        assert_eq!(
            parse_outcome("work\nSB-RESULT: done\n"),
            Some(Outcome::Done)
        );
        assert_eq!(
            parse_outcome("SB-RESULT: done\n**SB-RESULT: blocked missing API key**"),
            Some(Outcome::Blocked("missing API key".into()))
        );
        assert_eq!(
            parse_outcome("`SB-RESULT: needs-user choose a colour`"),
            Some(Outcome::NeedsUser("choose a colour".into()))
        );
        assert_eq!(parse_outcome("all good"), None);
        assert_eq!(parse_outcome("SB-RESULT: maybe"), None);
    }

    #[test]
    fn command_words() {
        assert_eq!(
            split_command(r#"node "C:\My Tools\agent.js" --flag  x"#),
            vec!["node", r"C:\My Tools\agent.js", "--flag", "x"]
        );
        assert_eq!(split_command(r#"a "" b"#), vec!["a", "", "b"]);
        assert!(split_command("   ").is_empty());
    }

    fn opts_for(model: Option<&str>, effort: Option<&str>) -> RunOptions {
        RunOptions {
            agent: Some("claude".into()),
            agent_cmd: None,
            task: None,
            limit: None,
            all: false,
            model: model.map(str::to_string),
            effort: effort.map(str::to_string),
            timeout_minutes: 1,
            allow_cmd: Vec::new(),
            dry_run: false,
        }
    }

    #[test]
    fn unattended_runs_need_every_choice_as_a_flag() {
        let never = &mut |_: &str, _: &[String]| -> Result<String> { panic!("asked") };
        let o = opts_for(None, None);
        let e = resolve_choices("claude", &o, 4, false, never).unwrap_err();
        assert!(e.to_string().contains("--model"), "{e}");

        let mut o = opts_for(Some("opus"), Some("high"));
        let e = resolve_choices("claude", &o, 4, false, never).unwrap_err();
        assert!(e.to_string().contains("--limit N or --all"), "{e}");

        o.limit = Some(2);
        let c = resolve_choices("claude", &o, 4, false, never).unwrap();
        assert_eq!(
            c,
            Choices {
                model: "opus".into(),
                effort: Some("high".into()),
                count: Some(2)
            }
        );
        o.limit = None;
        o.all = true;
        assert_eq!(
            resolve_choices("claude", &o, 4, false, never)
                .unwrap()
                .count,
            None
        );
    }

    #[test]
    fn unknown_models_and_efforts_are_refused() {
        let never = &mut |_: &str, _: &[String]| -> Result<String> { panic!("asked") };
        let mut o = opts_for(Some("gpt-9"), None);
        o.all = true;
        assert!(resolve_choices("claude", &o, 1, false, never).is_err());
        let mut o = opts_for(Some("opus"), Some("turbo"));
        o.all = true;
        assert!(resolve_choices("claude", &o, 1, false, never).is_err());
        let mut o = opts_for(Some("gemini-2.5-pro"), Some("high"));
        o.all = true;
        let e = resolve_choices("gemini", &o, 1, false, never).unwrap_err();
        assert!(e.to_string().contains("no effort"), "{e}");
    }

    #[test]
    fn a_terminal_run_asks_for_what_is_missing() {
        let mut asked = Vec::new();
        let ask = &mut |q: &str, options: &[String]| -> Result<String> {
            asked.push(q.to_string());
            Ok(if q.contains("model") {
                "sonnet".to_string()
            } else if q.contains("effort") {
                "default".to_string()
            } else {
                assert_eq!(options.last().unwrap(), "all");
                "3".to_string()
            })
        };
        let c = resolve_choices("claude", &opts_for(None, None), 9, true, ask).unwrap();
        assert_eq!(
            c,
            Choices {
                model: "sonnet".into(),
                effort: None,
                count: Some(3)
            }
        );
        assert_eq!(asked.len(), 3);
    }

    #[test]
    fn choices_reach_the_agent_command_line() {
        let base = |name: &str, args: &[&str]| Agent {
            name: name.into(),
            program: PathBuf::from(name),
            args: args.iter().map(|a| a.to_string()).collect(),
            model: None,
            effort: None,
        };
        let a = with_choices(base("claude", &["-p"]), "opus", Some("high"));
        assert_eq!(a.args, ["-p", "--model", "opus", "--effort", "high"]);
        assert_eq!(a.label(), "claude (opus, high)");
        let a = with_choices(
            base("codex", &["exec", "--sandbox", "x", "-"]),
            "gpt-6.2-sol",
            Some("low"),
        );
        assert_eq!(
            a.args,
            [
                "exec",
                "-m",
                "gpt-6.2-sol",
                "-c",
                "model_reasoning_effort=\"low\"",
                "--sandbox",
                "x",
                "-"
            ]
        );
        let a = with_choices(base("gemini", &["-p", "go"]), "gemini-2.5-pro", None);
        assert_eq!(a.args, ["-m", "gemini-2.5-pro", "-p", "go"]);
    }

    #[test]
    fn programs_come_from_the_acceptance_command_the_handoff_and_the_flag() {
        let mut t = Task::new(1, "x", "2026-01-01");
        t.accept = Some("cd cli && cargo test --locked | tee out; C:\\bin\\npm.exe run x".into());
        t.body = "**Commands**
git, cargo; bad;name

**Scope**
x"
        .into();
        let all = allowed_programs(&t, &["Rust-Analyzer".into(), "$(evil)".into()]);
        assert_eq!(
            all,
            ["cargo", "tee", "npm", "git", "bad", "name", "Rust-Analyzer"]
        );
        assert!(allowed_programs(&Task::new(2, "y", "2026-01-01"), &[]).is_empty());
    }

    #[test]
    fn claude_gets_one_allowlist_argument() {
        let agent = Agent {
            name: "claude".into(),
            program: PathBuf::from("claude"),
            args: vec!["-p".into()],
            model: None,
            effort: None,
        };
        let programs = ["cargo".to_string(), "git".to_string()];
        let (a, shell) = with_allowed(agent.clone(), &programs, false);
        assert_eq!(
            a.args,
            ["-p", "--allowedTools", "Bash(cargo:*),Bash(git:*)"]
        );
        assert_eq!(shell, Shell::Listed(programs.to_vec()));
        let (a, shell) = with_allowed(agent.clone(), &[], false);
        assert_eq!((a.args, shell), (vec!["-p".to_string()], Shell::Denied));
        let (a, shell) = with_allowed(agent.clone(), &programs, true);
        assert_eq!((a.args, shell), (vec!["-p".to_string()], Shell::Denied));
        let codex = Agent {
            name: "codex".into(),
            ..agent.clone()
        };
        assert_eq!(with_allowed(codex, &programs, false).1, Shell::Sandboxed);
        let gemini = Agent {
            name: "gemini".into(),
            args: vec!["-p".into(), "go".into()],
            ..agent
        };
        let (a, shell) = with_allowed(gemini, &programs, false);
        assert_eq!(
            a.args,
            [
                "--allowed-tools",
                "run_shell_command(cargo)",
                "--allowed-tools",
                "run_shell_command(git)",
                "-p",
                "go"
            ]
        );
        assert!(matches!(shell, Shell::Listed(_)));
    }

    #[test]
    fn gemini_policy_replaces_allowed_tools() {
        let gemini = Agent {
            name: "gemini".into(),
            program: PathBuf::from("gemini"),
            args: vec!["-p".into(), "go".into()],
            model: None,
            effort: None,
        };
        let programs = ["cargo".to_string(), "git".to_string()];
        let path = Path::new("policies/7.toml");
        let (a, shell) = with_allowed_policy(gemini.clone(), &programs, false, Some(path));
        assert_eq!(a.args, ["--policy", "policies/7.toml", "-p", "go"]);
        assert_eq!(shell, Shell::Listed(programs.to_vec()));
        let (a, _) = with_allowed_policy(gemini, &programs, false, None);
        assert_eq!(a.args[0], "--allowed-tools");
        let policy = gemini_policy(&programs);
        assert!(policy.contains("commandPrefix = \"cargo\""));
        assert!(policy.contains("commandPrefix = \"git\""));
        assert_eq!(policy.matches("decision = \"allow\"").count(), 2);
    }

    #[test]
    fn gemini_version_is_parsed() {
        assert_eq!(parse_version("0.68.1\n"), Some((0, 68)));
        assert_eq!(parse_version("gemini v0.70.0-nightly"), Some((0, 70)));
        assert_eq!(parse_version("no version"), None);
        assert!(parse_version("0.67.9").unwrap() < GEMINI_POLICY_FROM);
    }

    #[test]
    fn missing_programs_are_reported() {
        let m = missing_programs(&["definitely-not-a-program-sb".into()]);
        assert_eq!(m, ["definitely-not-a-program-sb"]);
    }
}
