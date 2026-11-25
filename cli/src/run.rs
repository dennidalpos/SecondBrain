//! `sb run`: works through a repository's open tasks unattended, one fresh agent process per task.
//!
//! Safety model: the run happens on its own `sb/run-*` branch created from a clean tree;
//! agents may only edit files (no command approval), never commit or push; `sb` commits
//! each task's changes locally and never pushes. The person reviews and merges the branch.

use crate::date;
use crate::ops;
use crate::store::{Dossier, Home, write_atomic};
use crate::task::{Status, Task};
use anyhow::{Context as _, Result, anyhow, bail};
use std::io::{BufRead, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

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
    pub timeout_minutes: u64,
    pub dry_run: bool,
}

/// A program and its fixed arguments; the prompt always goes to standard input.
#[derive(Clone, Debug)]
pub struct Agent {
    pub name: String,
    pub program: PathBuf,
    pub args: Vec<String>,
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

/// Tasks an unattended run may take: open, `todo`, not waiting on a person.
pub fn runnable(d: &Dossier, only: Option<u32>, limit: Option<usize>) -> Result<Vec<Task>> {
    let mut tasks: Vec<Task> = d.tasks()?;
    if let Some(id) = only {
        let t = tasks
            .into_iter()
            .find(|t| t.id == id)
            .ok_or_else(|| anyhow!("no task #{id}"))?;
        if t.status != Status::Todo {
            bail!("task #{id} is {}, not todo", t.status);
        }
        if t.needs_user {
            bail!("task #{id} needs you, so it cannot run unattended");
        }
        return Ok(vec![t]);
    }
    tasks.retain(|t| t.status == Status::Todo && !t.needs_user);
    ops::sort_open(&mut tasks);
    if let Some(n) = limit {
        tasks.truncate(n);
    }
    Ok(tasks)
}

pub fn prompt(d: &Dossier, root: &str, branch: &str, t: &Task) -> String {
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
    format!(
        "You are working unattended on one task in the Git repository at {root} (branch {branch}). \
Nobody can answer questions during this run.\n\n\
# Task #{id}: {title}\n\n{body}\n\n\
# Project context\n\n{context}\n\n\
# Rules\n\n\
- Work only on this task, with the smallest change that completes it; follow the repository's AGENTS.md.\n\
- Do not commit, push, tag, switch branches, rewrite history or delete branches. Leave your changes in the working tree: sb commits them after you finish.\n\
- Do not change files outside this repository.\n\
- If the task needs a person (a decision, credentials, access, a manual check), stop and say what is needed.\n\
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
    let mut child = Command::new(&agent.program)
        .args(&agent.args)
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("starting {}", agent.program.display()))?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let input = input.to_string();
    let writer = thread::spawn(move || {
        let _ = stdin.write_all(input.as_bytes());
    });
    let mut out = child.stdout.take().expect("piped stdout");
    let mut err = child.stderr.take().expect("piped stderr");
    let out_reader = thread::spawn(move || {
        let mut b = Vec::new();
        let _ = out.read_to_end(&mut b);
        b
    });
    let err_reader = thread::spawn(move || {
        let mut b = Vec::new();
        let _ = err.read_to_end(&mut b);
        b
    });
    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break Some(s);
        }
        if start.elapsed() >= timeout {
            timed_out = true;
            let _ = child.kill();
            break child.wait().ok();
        }
        thread::sleep(Duration::from_millis(200));
    };
    let _ = writer.join();
    let stdout = out_reader.join().unwrap_or_default();
    let stderr = err_reader.join().unwrap_or_default();
    let mut output = String::from_utf8_lossy(&stdout).into_owned();
    if !stderr.is_empty() {
        output.push_str("\n--- stderr ---\n");
        output.push_str(&String::from_utf8_lossy(&stderr));
    }
    Ok(Execution {
        output,
        exit: status.and_then(|s| s.code()),
        timed_out,
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
    let tasks = runnable(&d, opts.task, opts.limit)?;
    if tasks.is_empty() {
        return Ok(
            "No task can run unattended (open, todo and not waiting on you). Nothing to do.\n"
                .into(),
        );
    }
    if opts.dry_run {
        let mut s = format!("{} task(s) would run, in this order:\n", tasks.len());
        s.push_str(&ops::task_list_text(&tasks));
        return Ok(s);
    }

    let agent = match (&opts.agent_cmd, &opts.agent) {
        (Some(cmd), _) => custom_agent(cmd)?,
        (None, Some(name)) => known_agent(&name.to_lowercase())?,
        (None, None) => ask_agent()?,
    };
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
    let timeout = Duration::from_secs(opts.timeout_minutes.max(1) * 60);
    let logs = d.dir.join("runs");
    let mut summary = Vec::new();

    for task in tasks {
        progress(&format!("#{} {} ({})", task.id, task.title, agent.name));
        let mut t = task.clone();
        t.status = Status::Doing;
        t.updated = date::today();
        d.save_task(&t)?;

        let input = prompt(&d, &root, &branch, &t);
        let exec = execute(&agent, &root_path, &input, timeout)?;
        let log = logs.join(format!("{}-{}.log", date::stamp(), t.id));
        write_atomic(
            &log,
            &format!("# prompt\n\n{input}\n# output\n\n{}\n", exec.output),
        )?;

        let outcome = if exec.timed_out {
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
            t.status = Status::Blocked;
            t.body = note(
                &t.body,
                &agent.name,
                &format!("the agent switched to branch {now_branch}; run stopped"),
                &log,
            );
            d.save_task(&t)?;
            bail!(
                "the agent switched from {branch} to {now_branch}; the run stopped so nothing is committed on the wrong branch"
            );
        }

        let (status, needs_user, label) = match &outcome {
            Outcome::Done => (Status::Done, false, "done".to_string()),
            Outcome::Blocked(r) => (Status::Blocked, false, format!("blocked: {r}")),
            Outcome::NeedsUser(r) => (Status::Todo, true, format!("needs you: {r}")),
            Outcome::Failed(r) => (Status::Blocked, false, format!("failed: {r}")),
        };
        let changed = !git(&root_path, &["status", "--porcelain"])?.is_empty();
        let commit = if changed {
            git(&root_path, &["add", "-A"])?;
            let subject = if outcome == Outcome::Done {
                format!("{} (sb #{})", t.title, t.id)
            } else {
                format!("Not done: {} (sb #{})", t.title, t.id)
            };
            let body = format!("sb run with {}: {label}", agent.name);
            git(&root_path, &["commit", "-q", "-m", &subject, "-m", &body])?;
            Some(git(&root_path, &["rev-parse", "--short", "HEAD"])?)
        } else {
            None
        };

        t.status = status;
        t.needs_user = t.needs_user || needs_user;
        t.updated = date::today();
        let detail = match &commit {
            Some(c) => format!("{label}; commit {c} on {branch}"),
            None => format!("{label}; no file changed"),
        };
        t.body = note(&t.body, &agent.name, &detail, &log);
        d.save_task(&t)?;

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
}
