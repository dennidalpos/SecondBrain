//! Operations shared by the command line and the MCP server; each returns the text to show.

use crate::block;
use crate::git;
use crate::store::{Dossier, Home, write_atomic};
use crate::task::Task;
use anyhow::{Result, anyhow};
use std::fs;
use std::path::Path;

const CONTEXT_TASK_LIMIT: usize = 30;
const SEARCH_LIMIT: usize = 50;

/// Open tasks in working order: in progress, then priority (unset last), then id.
pub fn sort_open(tasks: &mut [Task]) {
    tasks.sort_by_key(|t| (t.status.rank(), t.priority.unwrap_or(9), t.id));
}

pub fn context_text(d: &Dossier) -> Result<String> {
    let mut s = format!("# {}\n\n## Context\n\n", d.meta.identity);
    let context = d.context();
    if context.trim().is_empty() {
        s.push_str("(empty: record the current state with `sb context --set`)\n");
    } else {
        s.push_str(context.trim_end());
        s.push('\n');
    }
    let decisions = d.decisions();
    if !decisions.is_empty() {
        s.push_str("\n## Recent decisions\n\n");
        let start = decisions.len().saturating_sub(10);
        for line in &decisions[start..] {
            s.push_str(line);
            s.push('\n');
        }
    }
    let mut open: Vec<Task> = d.tasks()?.into_iter().filter(Task::is_open).collect();
    sort_open(&mut open);
    s.push_str(&format!("\n## Open tasks ({})\n\n", open.len()));
    for t in open.iter().take(CONTEXT_TASK_LIMIT) {
        s.push_str(&format!("- {}\n", t.summary()));
    }
    if open.len() > CONTEXT_TASK_LIMIT {
        s.push_str(&format!(
            "- ... {} more: `sb task list`\n",
            open.len() - CONTEXT_TASK_LIMIT
        ));
    }
    Ok(s)
}

pub fn task_list_text(tasks: &[Task]) -> String {
    if tasks.is_empty() {
        return "No tasks.\n".into();
    }
    tasks.iter().map(|t| format!("{}\n", t.summary())).collect()
}

pub fn task_text(t: &Task) -> String {
    let mut s = format!(
        "{}\ncreated {}, updated {}",
        t.summary(),
        t.created,
        t.updated
    );
    if let Some(l) = &t.legacy_id {
        s.push_str(&format!(", v4 id {l}"));
    }
    s.push('\n');
    if !t.body.is_empty() {
        s.push('\n');
        s.push_str(&t.body);
        s.push('\n');
    }
    s
}

pub fn repos_text(home: &Home) -> Result<String> {
    let all = home.dossiers()?;
    if all.is_empty() {
        return Ok("No repositories yet: run `sb add` inside one.\n".into());
    }
    let mut s = String::new();
    for d in all {
        let open = d.tasks()?.iter().filter(|t| t.is_open()).count();
        let path = d
            .meta
            .paths
            .first()
            .cloned()
            .unwrap_or_else(|| "no checkout recorded".into());
        s.push_str(&format!("{}  {} open  {}\n", d.meta.identity, open, path));
    }
    Ok(s)
}

pub fn search_text(dossiers: &[Dossier], query: &str) -> Result<String> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Err(anyhow!("the search text is empty"));
    }
    let mut hits = Vec::new();
    for d in dossiers {
        let id = &d.meta.identity;
        for line in d
            .context()
            .lines()
            .filter(|l| l.to_lowercase().contains(&q))
        {
            hits.push(format!("{id} context: {}", line.trim()));
        }
        for line in d
            .decisions()
            .iter()
            .filter(|l| l.to_lowercase().contains(&q))
        {
            hits.push(format!("{id} decision {}", line.trim_start_matches("- ")));
        }
        for t in d.tasks()? {
            if t.title.to_lowercase().contains(&q) || t.body.to_lowercase().contains(&q) {
                hits.push(format!("{id} {}", t.summary()));
            }
        }
    }
    if hits.is_empty() {
        return Ok(format!("Nothing found for '{query}'.\n"));
    }
    let total = hits.len();
    let mut s: String = hits
        .into_iter()
        .take(SEARCH_LIMIT)
        .map(|h| h + "\n")
        .collect();
    if total > SEARCH_LIMIT {
        s.push_str(&format!(
            "... {} more results; narrow the search\n",
            total - SEARCH_LIMIT
        ));
    }
    Ok(s)
}

/// Writes the SecondBrain block into AGENTS.md and the pointer files that are asked for.
pub fn link_files(root: &Path, rules: &str, files: &[String]) -> Result<Vec<String>> {
    let mut msgs = Vec::new();
    for f in files {
        match f.trim().to_lowercase().as_str() {
            "agents" => {
                let path = root.join("AGENTS.md");
                let old = fs::read_to_string(&path).unwrap_or_default();
                let new = block::upsert(&old, &block::body(rules));
                if new != old {
                    write_atomic(&path, &new)?;
                    msgs.push(format!("updated {}", path.display()));
                }
            }
            name @ ("claude" | "gemini") => {
                let file = if name == "claude" {
                    "CLAUDE.md"
                } else {
                    "GEMINI.md"
                };
                let path = root.join(file);
                match fs::read_to_string(&path) {
                    Err(_) => {
                        write_atomic(&path, "@AGENTS.md\n")?;
                        msgs.push(format!("created {} (points to AGENTS.md)", path.display()));
                    }
                    Ok(text) if text.contains("@AGENTS.md") => {}
                    Ok(_) => msgs.push(format!(
                        "{file} exists and does not import AGENTS.md: add a line `@AGENTS.md` so the agent reads the SecondBrain block"
                    )),
                }
            }
            "" => {}
            other => {
                return Err(anyhow!(
                    "unknown file kind '{other}' (use agents, claude, gemini)"
                ));
            }
        }
    }
    Ok(msgs)
}

/// Removes the block and the pointer files that contain nothing else.
pub fn unlink_files(root: &Path) -> Result<Vec<String>> {
    let mut msgs = Vec::new();
    let agents = root.join("AGENTS.md");
    if let Ok(text) = fs::read_to_string(&agents)
        && let Some(rest) = block::remove(&text)
    {
        if rest.trim().is_empty() {
            fs::remove_file(&agents)?;
            msgs.push(format!("removed {}", agents.display()));
        } else {
            write_atomic(&agents, &rest)?;
            msgs.push(format!("removed the block from {}", agents.display()));
        }
    }
    for file in ["CLAUDE.md", "GEMINI.md"] {
        let path = root.join(file);
        if fs::read_to_string(&path)
            .map(|t| t.trim() == "@AGENTS.md")
            .unwrap_or(false)
        {
            fs::remove_file(&path)?;
            msgs.push(format!("removed {}", path.display()));
        }
    }
    Ok(msgs)
}

/// Rewrites the block in every recorded checkout that already has one.
pub fn sync_rules(home: &Home) -> Result<String> {
    let rules = home.rules();
    let body = block::body(&rules);
    let mut s = String::new();
    let mut updated = 0;
    for d in home.dossiers()? {
        for p in &d.meta.paths {
            let agents = Path::new(p).join("AGENTS.md");
            let Ok(old) = fs::read_to_string(&agents) else {
                continue;
            };
            if !block::has_block(&old) {
                continue;
            }
            let new = block::upsert(&old, &body);
            if new != old {
                write_atomic(&agents, &new)?;
                s.push_str(&format!("updated {}\n", agents.display()));
                updated += 1;
            }
        }
    }
    s.push_str(&format!("{updated} file(s) updated.\n"));
    Ok(s)
}

/// The checkout root of `path` and its identity.
pub fn checkout(path: &Path) -> Result<(String, String)> {
    let root = git::repo_root(path)
        .ok_or_else(|| anyhow!("{} is not inside a Git repository", path.display()))?;
    Ok((root.display().to_string(), git::identity(&root)))
}
