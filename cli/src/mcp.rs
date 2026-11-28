//! A small MCP server over stdio (newline-delimited JSON-RPC 2.0), for desktop apps and
//! agents without a shell. Run it with `sb mcp`; it exposes the same operations as the CLI.

use crate::kb;
use crate::ops;
use crate::store::Home;
use crate::task::{Status, one_line, parse_priority};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

const DEFAULT_PROTOCOL: &str = "2025-06-18";
/// Longest message accepted on standard input.
const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;

pub fn serve(home: Home) -> Result<()> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = if line.len() > MAX_MESSAGE_BYTES {
            Some(error(
                Value::Null,
                -32600,
                &format!("message too large (limit {MAX_MESSAGE_BYTES} bytes)"),
            ))
        } else {
            match serde_json::from_str::<Value>(&line) {
                Ok(msg) => handle(&home, &cwd, &msg),
                Err(e) => Some(error(Value::Null, -32700, &format!("parse error: {e}"))),
            }
        };
        if let Some(reply) = reply {
            writeln!(stdout, "{reply}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

/// Answers one JSON-RPC message; notifications get no answer.
pub fn handle(home: &Home, cwd: &Path, msg: &Value) -> Option<Value> {
    let id = msg.get("id").cloned()?;
    let method = msg["method"].as_str().unwrap_or_default();
    let params = &msg["params"];
    let result = match method {
        "initialize" => {
            let body = crate::block::body(&home.rules());
            let version = crate::block::directive_version(&body).unwrap_or("unknown");
            json!({
            "protocolVersion": params["protocolVersion"].as_str().unwrap_or(DEFAULT_PROTOCOL),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "secondbrain", "version": env!("CARGO_PKG_VERSION")},
            "instructions": format!("SecondBrain managed directive version: {version}. Private project context, decisions and tasks. Call get_context at the start of work on a linked repository; pass `repo` (from list_repos) when the server does not run inside that repository. If the user wants to set up a repository with missing or empty context, read get_guide(topic: onboarding). To work through tasks in chat, read get_guide(topic: chat).")
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({"tools": tools()}),
        "tools/call" => {
            let name = params["name"].as_str().unwrap_or_default();
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match call(home, cwd, name, &args) {
                Ok(text) => json!({"content": [{"type": "text", "text": text}], "isError": false}),
                Err(e) => {
                    json!({"content": [{"type": "text", "text": format!("{e:#}")}], "isError": true})
                }
            }
        }
        _ => return Some(error(id, -32601, &format!("method not found: {method}"))),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn repo_prop() -> Value {
    json!({"type": "string", "description": "Repository: identity such as github.com/owner/name, its last part, or a checkout folder. Optional when the server runs inside the repository."})
}

fn tool(name: &str, description: &str, props: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": props, "required": required}
    })
}

fn tools() -> Vec<Value> {
    vec![
        tool(
            "list_repos",
            "List the repositories SecondBrain knows, with their open task counts.",
            json!({}),
            &[],
        ),
        tool(
            "link_repo",
            "Link a local Git checkout and create its private dossier if needed. Use when the user wants to onboard a repository. Existing dossier data is preserved. The onboarding guide explains how to inspect the checkout and save an initial context.",
            json!({
                "path": {"type": "string", "description": "Absolute path to the Git checkout on the machine running sb mcp."},
                "link_agent_files": {"type": "boolean", "description": "Write the managed AGENTS.md block and the Claude pointer if requested; defaults to false."}
            }),
            &["path"],
        ),
        tool(
            "get_context",
            "Current state, recent decisions and open tasks of a repository. Call it before working on the repository. Pass budget (tokens) to keep the answer small.",
            json!({
                "repo": repo_prop(),
                "budget": {"type": "integer", "minimum": 1, "description": "Approximate token limit; rules are complete; a large state loses whole sections, tasks and decisions are trimmed to fit."}
            }),
            &[],
        ),
        tool(
            "list_tasks",
            "List a repository's tasks; open ones unless status is given.",
            json!({
                "repo": repo_prop(),
                "status": {"type": "string", "enum": ["open", "all", "todo", "doing", "blocked", "done"]}
            }),
            &[],
        ),
        tool(
            "get_task",
            "Show one task with its full description.",
            json!({"repo": repo_prop(), "id": {"type": "integer"}}),
            &["id"],
        ),
        tool(
            "add_task",
            "Create a task.",
            json!({
                "repo": repo_prop(),
                "title": {"type": "string"},
                "body": {"type": "string", "description": "Markdown description and acceptance criteria."},
                "priority": {"type": "integer", "minimum": 1, "maximum": 4, "description": "1 is the highest."},
                "needs_user": {"type": "boolean", "description": "True when a person must act or decide."}
            }),
            &["title"],
        ),
        tool(
            "ready_tasks",
            "List the tasks that can start now: todo, unblocked by other tasks, not claimed, not waiting on a person.",
            json!({"repo": repo_prop()}),
            &[],
        ),
        tool(
            "claim_task",
            "Take a ready task so no other agent works on it; the claim expires after `minutes`. Fails if the task is not ready.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "by": {"type": "string", "description": "Who claims it, for example the agent name."},
                "minutes": {"type": "integer", "minimum": 1, "description": "Lease length; 30 by default."}
            }),
            &["id", "by"],
        ),
        tool(
            "release_task",
            "Give a claimed task back (it becomes todo again).",
            json!({"repo": repo_prop(), "id": {"type": "integer", "description": "Task number."}, "by": {"type": "string", "description": "If set, release only if this holder still owns the active claim."}}),
            &["id"],
        ),
        tool(
            "update_task",
            "Change a task's status, title, priority, needs_user flag or body.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "by": {"type": "string", "description": "If set, update only if this holder still owns the active claim."},
                "status": {"type": "string", "enum": ["todo", "doing", "blocked", "done"]},
                "title": {"type": "string"},
                "priority": {"type": "integer", "minimum": 1, "maximum": 4},
                "needs_user": {"type": "boolean"},
                "body": {"type": "string"},
                "blocked_by": {"type": "array", "items": {"type": "integer"}, "description": "Ids of tasks that must be done first; an empty list clears."}
            }),
            &["id"],
        ),
        tool(
            "prepare_queue",
            "List the open tasks that wait for a person and can be prepared now (not claimed, not done). Interview the owner about each, then call prepare_task.",
            json!({"repo": repo_prop()}),
            &[],
        ),
        tool(
            "prepare_task",
            "Save the interview answers of one task as its unattended handoff and decide: ready clears needs_user, hold keeps it. The acceptance command cannot be set here.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "scope": {"type": "string", "description": "Files or areas in scope (required)."},
                "acceptance": {"type": "string", "description": "Result and acceptance criteria (required)."},
                "checks": {"type": "string"},
                "commands": {"type": "string", "description": "Programs the agent may run without asking, comma separated."},
                "inputs": {"type": "string", "description": "Inputs or access needed; note what is missing."},
                "decisions": {"type": "string", "description": "Decisions or constraints; note open ones."},
                "authorizations": {"type": "string", "description": "Approvals given before the run (push, installs, network, deletions, accounts); note missing ones."},
                "decision": {"type": "string", "enum": ["ready", "hold"], "description": "ready if the agent has everything, hold if a person must still act."}
            }),
            &["id", "scope", "acceptance", "decision"],
        ),
        tool(
            "add_decision",
            "Record a durable decision as one dated line.",
            json!({"repo": repo_prop(), "text": {"type": "string"}}),
            &["text"],
        ),
        tool(
            "set_context",
            "Replace the repository's current-state notes (keep them short).",
            json!({"repo": repo_prop(), "text": {"type": "string", "description": "Current-state notes in Markdown."}, "if_empty": {"type": "boolean", "description": "Save initial context only if the dossier still has no context."}}),
            &["text"],
        ),
        tool(
            "get_guide",
            "Explain SecondBrain workflows and commands.",
            json!({"topic": {"type": "string", "description": "overview, commands, onboarding, tasks, prepare, chat, sources, rules, skills, run, check or mcp. Defaults to overview."}}),
            &[],
        ),
        tool(
            "get_rules",
            "The general rules and the repository's own rules.",
            json!({"repo": repo_prop()}),
            &[],
        ),
        tool(
            "set_repo_rules",
            "Replace the repository's own rules (kept in the private dossier, not in the repository).",
            json!({"repo": repo_prop(), "text": {"type": "string"}}),
            &["text"],
        ),
        tool(
            "list_skills",
            "List the skills kept in SecondBrain with their descriptions.",
            json!({}),
            &[],
        ),
        tool(
            "get_skill",
            "Read a skill before doing the kind of work it covers.",
            json!({"name": {"type": "string"}}),
            &["name"],
        ),
        tool(
            "search",
            "Search context, decisions, tasks and sources; all repositories unless repo is given.",
            json!({"query": {"type": "string"}, "repo": repo_prop()}),
            &["query"],
        ),
        tool(
            "add_source",
            "Store a document, note, web page, chat or connector item as a source of the repository. Extract the text yourself (read the file, OCR, transcribe, fetch through a connector) and pass structured Markdown plus a short summary; sb never parses documents. Read get_guide(topic: sources) first. Ask the user for the PARA group and tags when unclear. Pass original_path to copy the original file into the folder that only the user reads.",
            json!({
                "repo": repo_prop(),
                "title": {"type": "string", "description": "Short title."},
                "text": {"type": "string", "description": "Extracted text in Markdown (headings, tables as Markdown, transcripts with timestamps). At most 2 MiB."},
                "kind": {"type": "string", "enum": ["file", "web", "note", "chat", "connector", "media"]},
                "origin": {"type": "string", "description": "URL, connector item or path the text came from. The same origin again makes a new revision."},
                "original_path": {"type": "string", "description": "Absolute path of the original file on the machine running sb mcp; it is copied once and never opened again."},
                "para": {"type": "string", "enum": ["project", "area", "resource", "archive"], "description": "project: tied to a goal or task; area: ongoing responsibility; resource: reference; archive: inactive. Defaults to project with task_id, else resource."},
                "tags": {"type": "array", "items": {"type": "string"}},
                "summary": {"type": "string", "description": "Three to five lines on what the source holds."},
                "task_id": {"type": "integer", "description": "Task this source belongs to."},
                "allow_sensitive": {"type": "boolean", "description": "Set only after the user agreed to keep text that looks like secrets or personal data."}
            }),
            &["title", "text"],
        ),
        tool(
            "list_sources",
            "List the repository's current sources, newest first, archive last.",
            json!({
                "repo": repo_prop(),
                "para": {"type": "string", "enum": ["project", "area", "resource", "archive"]},
                "tag": {"type": "string"},
                "task_id": {"type": "integer"}
            }),
            &[],
        ),
        tool(
            "get_source",
            "Read one source with its summary and chunks. Pass chunk to read a single chunk or budget (tokens) to keep the answer small.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "chunk": {"type": "integer", "minimum": 1},
                "budget": {"type": "integer", "minimum": 1}
            }),
            &["id"],
        ),
        tool(
            "search_sources",
            "Search the repository's sources (ranked, with snippets); archived sources rank lower.",
            json!({
                "repo": repo_prop(),
                "query": {"type": "string"},
                "para": {"type": "string", "enum": ["project", "area", "resource", "archive"]},
                "limit": {"type": "integer", "minimum": 1}
            }),
            &["query"],
        ),
        tool(
            "update_source",
            "Reorganize a source: change its PARA group, title, summary, tags or task. The text and the original stay as they are.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "title": {"type": "string"},
                "para": {"type": "string", "enum": ["project", "area", "resource", "archive"]},
                "summary": {"type": "string"},
                "add_tags": {"type": "array", "items": {"type": "string"}},
                "remove_tags": {"type": "array", "items": {"type": "string"}},
                "task_id": {"type": "integer", "description": "0 clears the link."}
            }),
            &["id"],
        ),
    ]
}

fn call(home: &Home, cwd: &Path, name: &str, args: &Value) -> Result<String> {
    let repo = args["repo"].as_str();
    let str_arg = |k: &str| -> Result<String> {
        args[k]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| anyhow!("missing '{k}'"))
    };
    let id_arg = || -> Result<u32> {
        args["id"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .ok_or_else(|| anyhow!("missing or invalid 'id'"))
    };
    let priority_arg = || -> Result<Option<u8>> {
        match &args["priority"] {
            Value::Null => Ok(None),
            v => Ok(Some(parse_priority(v.to_string().trim_matches('"'))?)),
        }
    };
    let holder_arg = || match args.get("by") {
        None => Ok(None),
        Some(Value::String(holder)) if !holder.trim().is_empty() => Ok(Some(holder.as_str())),
        Some(_) => bail!("by must be a non-empty string"),
    };
    let source_id = || -> Result<i64> {
        args["id"]
            .as_i64()
            .ok_or_else(|| anyhow!("missing or invalid 'id'"))
    };
    let opt_str = |k: &str| -> Result<Option<String>> {
        match &args[k] {
            Value::Null => Ok(None),
            Value::String(s) => Ok(Some(s.clone())),
            _ => bail!("{k} must be a string"),
        }
    };
    let str_list = |k: &str| -> Result<Vec<String>> {
        match &args[k] {
            Value::Null => Ok(Vec::new()),
            Value::Array(items) => items
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .ok_or_else(|| anyhow!("{k} must be a list of strings"))
                })
                .collect(),
            _ => bail!("{k} must be a list of strings"),
        }
    };
    let opt_u32 = |k: &str| -> Result<Option<u32>> {
        match &args[k] {
            Value::Null => Ok(None),
            v => v
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .map(Some)
                .ok_or_else(|| anyhow!("{k} must be a non-negative integer")),
        }
    };
    match name {
        "add_source" => {
            let d = home.resolve_repo(repo, cwd)?;
            let title = str_arg("title")?;
            let text = str_arg("text")?;
            let kind = opt_str("kind")?;
            let origin = opt_str("origin")?;
            let para = opt_str("para")?;
            let summary = opt_str("summary")?;
            let original = match opt_str("original_path")? {
                Some(p) => {
                    let p = PathBuf::from(p);
                    if !p.is_absolute() {
                        bail!("pass an absolute original_path");
                    }
                    Some(p)
                }
                None => None,
            };
            let added = kb::add(
                home,
                &d,
                kb::NewSource {
                    title: &title,
                    text: &text,
                    kind: kind.as_deref(),
                    origin: origin.as_deref(),
                    original: original.as_deref(),
                    para: para.as_deref(),
                    tags: kb::parse_tags(&str_list("tags")?)?,
                    summary: summary.as_deref(),
                    task: opt_u32("task_id")?,
                    by: Some("mcp"),
                    allow_sensitive: args["allow_sensitive"].as_bool().unwrap_or(false),
                },
            )?;
            Ok(added.text(&title))
        }
        "list_sources" => {
            let d = home.resolve_repo(repo, cwd)?;
            let para = opt_str("para")?;
            let tag = opt_str("tag")?;
            Ok(kb::list_text(&kb::list(
                &d,
                &kb::Filter {
                    para: para.as_deref(),
                    tag: tag.as_deref(),
                    task: opt_u32("task_id")?,
                },
            )?))
        }
        "get_source" => {
            let d = home.resolve_repo(repo, cwd)?;
            kb::show(
                &d,
                source_id()?,
                opt_u32("chunk")?.map(|c| c as usize).filter(|c| *c > 0),
                opt_u32("budget")?.map(|b| b as usize).filter(|b| *b > 0),
            )
        }
        "search_sources" => {
            let d = home.resolve_repo(repo, cwd)?;
            let para = opt_str("para")?;
            kb::search_text(
                &d,
                &str_arg("query")?,
                para.as_deref(),
                opt_u32("limit")?.map_or(20, |l| l as usize),
            )
        }
        "update_source" => {
            let d = home.resolve_repo(repo, cwd)?;
            let s = kb::update(
                &d,
                source_id()?,
                &kb::Update {
                    title: opt_str("title")?,
                    para: opt_str("para")?,
                    summary: opt_str("summary")?,
                    add_tags: str_list("add_tags")?,
                    remove_tags: str_list("remove_tags")?,
                    task: opt_u32("task_id")?,
                },
            )?;
            Ok(format!("Updated {}\n", kb::line(&s)))
        }
        "list_repos" => {
            home.require()?;
            ops::repos_text(home)
        }
        "link_repo" => {
            let path = PathBuf::from(str_arg("path")?);
            if !path.is_absolute() {
                bail!("pass an absolute path to the local Git checkout");
            }
            let files = match args.get("link_agent_files") {
                None | Some(Value::Bool(false)) => Vec::new(),
                Some(Value::Bool(true)) => vec!["agents".into(), "claude".into()],
                Some(_) => bail!("link_agent_files must be a boolean"),
            };
            ops::link_checkout(home, &path, &files, true)
        }
        "get_context" => ops::context_with_budget(
            home,
            &home.resolve_repo(repo, cwd)?,
            args["budget"]
                .as_u64()
                .map(|b| b as usize)
                .filter(|b| *b > 0),
        ),
        "list_tasks" => {
            let d = home.resolve_repo(repo, cwd)?;
            let filter = args["status"].as_str().unwrap_or("open");
            let mut tasks = d.tasks()?;
            match filter {
                "open" => {
                    tasks.retain(|t| t.is_open());
                    ops::sort_open(&mut tasks);
                }
                "all" => {}
                s => {
                    let s = Status::parse(s)?;
                    tasks.retain(|t| t.status == s);
                }
            }
            Ok(ops::task_list_text(&tasks))
        }
        "prepare_queue" => {
            let d = home.resolve_repo(repo, cwd)?;
            let tasks = crate::prepare::queue(&d)?;
            if tasks.is_empty() {
                return Ok("No task is waiting for input.
"
                .into());
            }
            Ok(ops::task_list_text(&tasks))
        }
        "prepare_task" => {
            let d = home.resolve_repo(repo, cwd)?;
            let text = |name: &str| args[name].as_str().unwrap_or_default().to_string();
            let ready = match args["decision"].as_str() {
                Some("ready") => true,
                Some("hold") => false,
                _ => bail!("decision must be ready or hold"),
            };
            let answers = crate::prepare::Answers {
                scope: text("scope"),
                acceptance: text("acceptance"),
                checks: text("checks"),
                commands: text("commands"),
                inputs: text("inputs"),
                decisions: text("decisions"),
                authorizations: text("authorizations"),
                accept: String::new(),
            };
            crate::prepare::save(&d, id_arg()?, &answers, ready, None)
        }
        "get_task" => Ok(ops::task_text(
            &home.resolve_repo(repo, cwd)?.task(id_arg()?)?,
        )),
        "add_task" => {
            let d = home.resolve_repo(repo, cwd)?;
            let t = d.add_task(
                &str_arg("title")?,
                args["body"].as_str().unwrap_or_default(),
                priority_arg()?,
                args["needs_user"].as_bool().unwrap_or(false),
            )?;
            Ok(format!("Created {}\n", t.summary()))
        }
        "update_task" => {
            let d = home.resolve_repo(repo, cwd)?;
            let holder = holder_arg()?;
            let text_arg = |name| {
                if args[name].is_null() {
                    Ok(None)
                } else {
                    args[name]
                        .as_str()
                        .map(Some)
                        .ok_or_else(|| anyhow!("{name} must be a string"))
                }
            };
            let t = d.update_task(id_arg()?, |t| {
                if let Some(holder) = holder {
                    t.require_claim_by(holder)?;
                }
            let mut changed = false;
            if let Some(s) = text_arg("status")? {
                t.status = Status::parse(s)?;
                    if holder.is_some() && t.status != Status::Doing {
                        t.claimed_by = None;
                        t.claimed_until = None;
                    }
                changed = true;
            }
            if let Some(s) = text_arg("title")? {
                if s.trim().is_empty() {
                    bail!("the title is empty");
                }
                t.title = one_line(s);
                changed = true;
            }
            if let Some(p) = priority_arg()? {
                t.priority = Some(p);
                changed = true;
            }
            if let Some(b) = args["needs_user"].as_bool() {
                t.needs_user = b;
                changed = true;
            }
            if let Some(b) = text_arg("body")? {
                t.body = b.trim().to_string();
                changed = true;
            }
            if !args["blocked_by"].is_null() {
                let list = args["blocked_by"].as_array()
                    .ok_or_else(|| anyhow!("blocked_by must be an array of task ids"))?;
                t.blocked_by = list.iter().map(|value| {
                    value.as_u64().and_then(|id| u32::try_from(id).ok())
                        .ok_or_else(|| anyhow!("invalid task id in blocked_by"))
                }).collect::<Result<Vec<_>>>()?;
                t.blocker_keys.clear();
                changed = true;
            }
            if !changed {
                bail!(
                    "nothing to change: pass status, title, priority, needs_user, body or blocked_by"
                );
            }
                Ok(())
            })?;
            Ok(format!("Updated {}\n", t.summary()))
        }
        "ready_tasks" => Ok(ops::task_list_text(
            &home.resolve_repo(repo, cwd)?.ready_tasks()?,
        )),
        "claim_task" => {
            let d = home.resolve_repo(repo, cwd)?;
            let minutes = args["minutes"].as_u64().unwrap_or(30);
            let t = d.claim_task(id_arg()?, &str_arg("by")?, minutes)?;
            Ok(format!("Claimed {} for {minutes} min\n", t.summary()))
        }
        "release_task" => Ok(format!(
            "Released {}\n",
            home.resolve_repo(repo, cwd)?
                .release_task_by(id_arg()?, holder_arg()?)?
                .summary()
        )),
        "add_decision" => Ok(format!(
            "Recorded {}\n",
            home.resolve_repo(repo, cwd)?
                .add_decision(&str_arg("text")?)?
        )),
        "set_context" => {
            let dossier = home.resolve_repo(repo, cwd)?;
            let text = str_arg("text")?;
            match args.get("if_empty") {
                None | Some(Value::Bool(false)) => {
                    dossier.set_context(&text)?;
                    Ok("Context replaced.\n".into())
                }
                Some(Value::Bool(true)) => {
                    dossier.set_initial_context(&text)?;
                    Ok("Initial context saved.\n".into())
                }
                Some(_) => bail!("if_empty must be a boolean"),
            }
        }
        "get_guide" => crate::guide::text(args["topic"].as_str()).map_err(|e| anyhow!(e)),
        "get_rules" => {
            home.require()?;
            let d = home.resolve_repo(repo, cwd).ok();
            Ok(ops::rules_text(home, d.as_ref()))
        }
        "set_repo_rules" => {
            let d = home.resolve_repo(repo, cwd)?;
            d.set_rules(&str_arg("text")?)?;
            Ok(format!("Rules of {} replaced.\n", d.meta.identity))
        }
        "list_skills" => {
            home.require()?;
            crate::skills::list_text(home)
        }
        "get_skill" => {
            home.require()?;
            crate::skills::show(home, &str_arg("name")?)
        }
        "search" => {
            home.require()?;
            let query = str_arg("query")?;
            match repo {
                Some(_) => ops::search(home, &[home.resolve_repo(repo, cwd)?], &query),
                None => ops::search(home, &home.dossiers()?, &query),
            }
        }
        other => bail!("unknown tool '{other}'"),
    }
}
