//! The task interview saves a handoff only after an explicit decision.

use crate::store::Dossier;
use crate::task::{Status, Task};
use anyhow::{Result, bail};
use std::io::{BufRead, Write};

const BEGIN: &str = "<!-- sb:handoff:begin -->";
const END: &str = "<!-- sb:handoff:end -->";

pub(crate) fn can_prepare(task: &Task, now: u64) -> bool {
    !task.is_claimed(now)
        && (matches!(task.status, Status::Todo | Status::Blocked)
            || (task.status == Status::Doing && task.claimed_until.is_some()))
}

fn ask(input: &mut dyn BufRead, output: &mut dyn Write, question: &str) -> Result<String> {
    write!(output, "{question}\n> ")?;
    output.flush()?;
    let mut answer = String::new();
    if input.read_line(&mut answer)? == 0 {
        bail!("interview ended before confirmation; the task was left unchanged");
    }
    Ok(answer.trim().to_string())
}

fn update_handoff(body: &str, handoff: &str) -> String {
    let section = format!("{BEGIN}\n## Unattended handoff\n\n{handoff}{END}");
    if let Some((before, rest)) = body.split_once(BEGIN)
        && let Some((_, after)) = rest.split_once(END)
    {
        return format!("{before}{section}{after}");
    }
    if body.trim().is_empty() {
        section
    } else {
        format!("{}\n\n{section}", body.trim_end())
    }
}

pub(crate) fn run(
    dossier: &Dossier,
    id: u32,
    input: &mut dyn BufRead,
    output: &mut dyn Write,
) -> Result<String> {
    let original = dossier.task(id)?;
    if !can_prepare(&original, crate::date::now_secs()) {
        bail!("task #{id} is closed, claimed, or already in progress");
    }
    writeln!(output, "{}", crate::ops::task_text(&original))?;
    writeln!(
        output,
        "Describe the work and identify any missing inputs before handing this task to an agent."
    )?;
    let scope = ask(
        input,
        output,
        "Which files or areas are in scope? (required)",
    )?;
    let criteria = ask(
        input,
        output,
        "What result and acceptance criteria should the agent deliver? (required)",
    )?;
    if scope.is_empty() || criteria.is_empty() {
        bail!("scope and acceptance criteria are required; the task was left unchanged");
    }
    let checks = ask(input, output, "What checks should be run? (optional)")?;
    let accept = ask(
        input,
        output,
        "Acceptance command for sb run? (Enter keeps the current setting)",
    )?;
    let commands = ask(
        input,
        output,
        "Which programs may the agent run without asking (build, test, lint), comma separated, such as cargo, npm? Programs in the acceptance command are included. (optional)",
    )?;
    let inputs = ask(
        input,
        output,
        "What inputs or access are required? Note what is still missing. (optional)",
    )?;
    let decisions = ask(
        input,
        output,
        "What decisions or constraints apply? Note any open decisions. (optional)",
    )?;
    let approvals = ask(
        input,
        output,
        "Which approvals are needed before the run starts (push, installs, network, deletions, accounts)? Note any still missing. (optional)",
    )?;

    let answers = Answers {
        scope,
        acceptance: criteria,
        checks,
        commands,
        inputs,
        decisions,
        authorizations: approvals,
        accept,
    };
    let handoff = answers.handoff();
    writeln!(
        output,
        "
{handoff}"
    )?;
    if !answers.accept.is_empty() {
        writeln!(
            output,
            "Acceptance command: {}
",
            answers.accept
        )?;
    }
    let ready = match ask(
        input,
        output,
        "Type ready if the agent has what it needs, hold if a person must act, or cancel to discard. (default: cancel)",
    )?
    .to_ascii_lowercase()
    .as_str()
    {
        "ready" => true,
        "hold" => false,
        "" | "cancel" => return Ok(format!("Task #{id} left unchanged.\n")),
        _ => bail!("choose ready, hold or cancel; the task was left unchanged"),
    };

    save(dossier, id, &answers, ready, Some(&original))
}

/// Saves the handoff and the decision; `expected` guards against edits made meanwhile.
pub(crate) fn save(
    dossier: &Dossier,
    id: u32,
    answers: &Answers,
    ready: bool,
    expected: Option<&Task>,
) -> Result<String> {
    if answers.scope.trim().is_empty() || answers.acceptance.trim().is_empty() {
        bail!("scope and acceptance criteria are required; the task was left unchanged");
    }
    let handoff = answers.handoff();
    let task = dossier.update_task(id, |task| {
        if expected.is_some_and(|e| task != e) || !can_prepare(task, crate::date::now_secs()) {
            bail!("task #{id} changed during the interview, is closed or claimed; check it again");
        }
        task.body = update_handoff(&task.body, &handoff);
        if !answers.accept.is_empty() {
            task.accept = Some(answers.accept.clone());
        }
        if ready {
            task.status = Status::Todo;
            task.claimed_by = None;
            task.claimed_until = None;
        }
        task.needs_user = !ready;
        Ok(())
    })?;

    let next = if ready {
        format!("Preview eligibility in the checkout with sb run --task {id} --dry-run.")
    } else {
        "Run the interview again when the missing input is available.".into()
    };
    Ok(format!(
        "Saved {}
{next}
",
        task.summary()
    ))
}

/// Open tasks that wait on a person and can be prepared now.
pub(crate) fn queue(dossier: &Dossier) -> Result<Vec<Task>> {
    let now = crate::date::now_secs();
    let mut tasks = dossier.tasks()?;
    tasks.retain(|t| t.needs_user && can_prepare(t, now));
    crate::ops::sort_open(&mut tasks);
    Ok(tasks)
}

#[derive(Default)]
pub(crate) struct Answers {
    pub scope: String,
    pub acceptance: String,
    pub checks: String,
    pub commands: String,
    pub inputs: String,
    pub decisions: String,
    pub authorizations: String,
    /// CLI only; empty keeps the current acceptance command.
    pub accept: String,
}

impl Answers {
    fn handoff(&self) -> String {
        let mut handoff = String::new();
        for (label, answer) in [
            ("Scope", &self.scope),
            ("Acceptance", &self.acceptance),
            ("Checks", &self.checks),
            ("Commands", &self.commands),
            ("Inputs", &self.inputs),
            ("Decisions", &self.decisions),
            ("Authorizations", &self.authorizations),
        ] {
            let answer = answer.trim();
            if !answer.is_empty() {
                handoff.push_str(&format!(
                    "**{label}**
{answer}

"
                ));
            }
        }
        handoff
    }
}

/// Text for `sb prepare`: the queue (or one task) and how an agent interviews the owner.
pub(crate) fn instructions(dossier: &Dossier, id: Option<u32>) -> Result<String> {
    let mut out = String::new();
    match id {
        Some(id) => {
            let task = dossier.task(id)?;
            if !can_prepare(&task, crate::date::now_secs()) {
                bail!("task #{id} is closed, claimed, or already in progress");
            }
            out.push_str(&crate::ops::task_text(&task));
        }
        None => {
            let tasks = queue(dossier)?;
            if tasks.is_empty() {
                return Ok("No task is waiting for input.
"
                .into());
            }
            out.push_str(&format!(
                "{} task(s) to prepare:
",
                tasks.len()
            ));
            out.push_str(&crate::ops::task_list_text(&tasks));
        }
    }
    out.push_str(
        "
Agent: read `sb guide prepare` (MCP get_guide topic prepare). For each task ask the owner with the structured question tool: scope (required), acceptance (required), checks, commands, inputs, decisions, authorizations. Save with MCP prepare_task (decision ready or hold). In a terminal use `sb task prepare <id>`.
",
    );
    Ok(out)
}
