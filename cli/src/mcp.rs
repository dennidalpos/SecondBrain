//! A small MCP server over stdio (newline-delimited JSON-RPC 2.0), for desktop apps and
//! agents without a shell. Run it with `sb mcp`; it exposes the same operations as the CLI.

use crate::ops;
use crate::store::Home;
use crate::task::{Status, one_line, parse_priority};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

const DEFAULT_PROTOCOL: &str = "2025-06-18";

pub fn serve(home: Home) -> Result<()> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(msg) => handle(&home, &cwd, &msg),
            Err(e) => Some(error(Value::Null, -32700, &format!("parse error: {e}"))),
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
        "initialize" => json!({
            "protocolVersion": params["protocolVersion"].as_str().unwrap_or(DEFAULT_PROTOCOL),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "secondbrain", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "Private project context, decisions and tasks. Call get_context at the start of work on a repository; pass `repo` (from list_repos) when the server does not run inside that repository."
        }),
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
            "get_context",
            "Current state, recent decisions and open tasks of a repository. Call it before working on the repository.",
            json!({"repo": repo_prop()}),
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
            "update_task",
            "Change a task's status, title, priority, needs_user flag or body.",
            json!({
                "repo": repo_prop(),
                "id": {"type": "integer"},
                "status": {"type": "string", "enum": ["todo", "doing", "blocked", "done"]},
                "title": {"type": "string"},
                "priority": {"type": "integer", "minimum": 1, "maximum": 4},
                "needs_user": {"type": "boolean"},
                "body": {"type": "string"}
            }),
            &["id"],
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
            json!({"repo": repo_prop(), "text": {"type": "string"}}),
            &["text"],
        ),
        tool(
            "search",
            "Search context, decisions and tasks; all repositories unless repo is given.",
            json!({"query": {"type": "string"}, "repo": repo_prop()}),
            &["query"],
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
    match name {
        "list_repos" => {
            home.require()?;
            ops::repos_text(home)
        }
        "get_context" => ops::context_text(&home.resolve_repo(repo, cwd)?),
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
            let mut t = d.task(id_arg()?)?;
            let mut changed = false;
            if let Some(s) = args["status"].as_str() {
                t.status = Status::parse(s)?;
                changed = true;
            }
            if let Some(s) = args["title"].as_str() {
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
            if let Some(b) = args["body"].as_str() {
                t.body = b.trim().to_string();
                changed = true;
            }
            if !changed {
                bail!("nothing to change: pass status, title, priority, needs_user or body");
            }
            t.updated = crate::date::today();
            d.save_task(&t)?;
            Ok(format!("Updated {}\n", t.summary()))
        }
        "add_decision" => Ok(format!(
            "Recorded {}\n",
            home.resolve_repo(repo, cwd)?
                .add_decision(&str_arg("text")?)?
        )),
        "set_context" => {
            home.resolve_repo(repo, cwd)?
                .set_context(&str_arg("text")?)?;
            Ok("Context replaced.\n".into())
        }
        "search" => {
            home.require()?;
            let query = str_arg("query")?;
            match repo {
                Some(_) => ops::search_text(&[home.resolve_repo(repo, cwd)?], &query),
                None => ops::search_text(&home.dossiers()?, &query),
            }
        }
        other => bail!("unknown tool '{other}'"),
    }
}
