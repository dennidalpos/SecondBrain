//! Operations shared by the command line and the MCP server; each returns the text to show.

use crate::block;
use crate::git;
use crate::store::{Dossier, Home, write_atomic};
use crate::task::Task;
use anyhow::{Context as _, Result, anyhow, bail};
use std::fs;
use std::path::{Path, PathBuf};

const CONTEXT_TASK_LIMIT: usize = 30;
const SEARCH_LIMIT: usize = 50;
/// `sb context --compact` without a budget.
pub const COMPACT_BUDGET: usize = 1500;
/// A state larger than this many tokens is worth compacting (doctor warns).
pub const CONTEXT_WARN_TOKENS: usize = 3000;

/// Open tasks in working order: in progress, then priority (unset last), then id.
pub fn sort_open(tasks: &mut [Task]) {
    tasks.sort_by_key(|t| (t.status.rank(), t.priority.unwrap_or(9), t.id));
}

pub fn context_text(home: &Home, d: &Dossier) -> Result<String> {
    context_with_budget(home, d, None)
}

/// A rough token count: one token per four characters.
pub fn tokens(text: &str) -> usize {
    text.chars().count().div_ceil(4)
}

/// Cuts a line to `max` characters, ending with an ellipsis.
fn clip(line: &str, max: usize) -> String {
    if line.chars().count() <= max {
        return line.to_string();
    }
    let mut s: String = line.chars().take(max.saturating_sub(1)).collect();
    s.push('…');
    s
}

/// The context of a repository. With `budget` (in tokens, estimated) it stays within that size:
/// the repository rules come in full and the state is trimmed by heading only when it is large; then open tasks (in progress
/// first), recent decisions (newest first, long ones clipped) and skills share what is left, and
/// each omission says how to read the rest. Without a budget the usual limits apply.
pub fn context_with_budget(home: &Home, d: &Dossier, budget: Option<usize>) -> Result<String> {
    context_with_options(home, d, budget, false)
}

/// Splits Markdown into a preamble and sections that start at a heading (outside code fences).
fn sections(text: &str) -> (String, Vec<(String, String)>) {
    let mut pre = String::new();
    let mut out: Vec<(String, String)> = Vec::new();
    let mut fenced = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
        }
        if !fenced && line.starts_with('#') && line.trim_start_matches('#').starts_with(' ') {
            out.push((
                line.trim_start_matches('#').trim().to_string(),
                String::new(),
            ));
        }
        let target = match out.last_mut() {
            Some((_, body)) => body,
            None => &mut pre,
        };
        target.push_str(line);
        target.push('\n');
    }
    (pre, out)
}

/// Keeps a Markdown state within `max` tokens by dropping whole sections (split by headings).
/// The preamble stays; sections about the current state, next steps, decisions or rules go
/// first, then the others in document order. Dropped sections are named in a pointer line.
pub fn trim_sections(text: &str, max: usize) -> String {
    if tokens(text) <= max {
        return text.to_string();
    }
    let (pre, secs) = sections(text);
    let urgent = |h: &str| {
        let h = h.to_lowercase();
        [
            "current",
            "state",
            "next",
            "open",
            "todo",
            "decision",
            "rule",
            "constraint",
        ]
        .iter()
        .any(|k| h.contains(k))
    };
    let mut order: Vec<usize> = (0..secs.len()).collect();
    order.sort_by_key(|i| (!urgent(&secs[*i].0), *i));
    let mut left = max.saturating_sub(tokens(&pre) + 40);
    let mut keep = vec![false; secs.len()];
    for i in order {
        let cost = tokens(&secs[i].1);
        if cost <= left {
            left -= cost;
            keep[i] = true;
        }
    }
    let mut s = pre;
    let mut omitted = Vec::new();
    for (i, (head, body)) in secs.iter().enumerate() {
        if keep[i] {
            s.push_str(body);
        } else {
            omitted.push(head.as_str());
        }
    }
    if !omitted.is_empty() {
        if !s.ends_with('\n') {
            s.push('\n');
        }
        s.push_str(&format!(
            "\n({} sections omitted: {}; read all with `sb context --budget 0`)\n",
            omitted.len(),
            omitted.join(", ")
        ));
    }
    s
}

/// Like `context_with_budget`; `compact` also trims to a default budget when none is set.
pub fn context_with_options(
    home: &Home,
    d: &Dossier,
    budget: Option<usize>,
    compact: bool,
) -> Result<String> {
    let budget = budget.or(compact.then_some(COMPACT_BUDGET));
    let mut s = format!("# {}\n\n## Context\n\n", d.meta.identity);
    let context = d.context();
    if context.trim().is_empty() {
        s.push_str(
            "(empty: follow `sb guide onboarding` or `get_guide` with topic `onboarding`)\n",
        );
    } else {
        let text = match budget {
            Some(b) => trim_sections(context.trim_end(), (b / 2).max(200)),
            None => context.trim_end().to_string(),
        };
        s.push_str(text.trim_end());
        s.push('\n');
    }
    let rules = d.rules();
    if !rules.trim().is_empty() {
        s.push_str("\n## Repository rules\n\n");
        s.push_str(rules.trim_end());
        s.push('\n');
    }
    let fixed = tokens(&s);

    let mut open: Vec<Task> = d.tasks()?.into_iter().filter(Task::is_open).collect();
    sort_open(&mut open);
    let decisions = d.decisions()?;
    let skills = crate::skills::list(home)?;

    // What is left after the fixed part, split: tasks first, then decisions, then skills.
    let mut left = budget.map(|b| b.saturating_sub(fixed + 40));

    // Tasks (best first).
    let task_cap = left.map(|l| l / 2);
    let mut task_lines = Vec::new();
    let mut used = 0;
    for t in open.iter().take(CONTEXT_TASK_LIMIT) {
        let line = format!("- {}\n", clip(&t.summary(), 200));
        let cost = tokens(&line);
        // A tight budget still shows the first few tasks.
        if task_cap.is_some_and(|c| used + cost > c) && task_lines.len() >= 3 {
            break;
        }
        used += cost;
        task_lines.push(line);
    }
    left = left.map(|l| l.saturating_sub(used));
    s.push_str(&format!("\n## Open tasks ({})\n\n", open.len()));
    for l in &task_lines {
        s.push_str(l);
    }
    if open.len() > task_lines.len() {
        s.push_str(&format!(
            "- ... {} more: `sb task list`\n",
            open.len() - task_lines.len()
        ));
    }

    // Decisions (newest first in the budget, printed oldest to newest).
    if !decisions.is_empty() {
        let cap = left.map(|l| l * 3 / 5);
        let mut kept: Vec<String> = Vec::new();
        let mut used = 0;
        for line in decisions.iter().rev().take(10) {
            // A line is kept whole when it fits, clipped when only a short form fits.
            let mut text = line.clone();
            let mut cost = tokens(&text) + 1;
            if cap.is_some_and(|c| used + cost > c) {
                text = clip(line, 240);
                cost = tokens(&text) + 1;
                if cap.is_some_and(|c| used + cost > c) && !kept.is_empty() {
                    break;
                }
            }
            used += cost;
            kept.push(text);
        }
        left = left.map(|l| l.saturating_sub(used));
        s.push_str("\n## Recent decisions\n\n");
        for line in kept.iter().rev() {
            s.push_str(line);
            s.push('\n');
        }
        if budget.is_some() && decisions.len() > kept.len() {
            s.push_str(&format!(
                "- ... {} older: `sb search <words>`\n",
                decisions.len() - kept.len()
            ));
        }
    }

    // Sources: counts per PARA group and the newest titles.
    if let Some(section) = crate::kb::overview(d, left)? {
        left = left.map(|l| l.saturating_sub(tokens(&section)));
        s.push_str(&section);
    }

    // Skills: with descriptions while they fit, then names only.
    if !skills.is_empty() {
        let full: Vec<String> = skills
            .iter()
            .map(|k| format!("- {}: {}\n", k.name, clip(&k.description, 90)))
            .collect();
        let names = format!(
            "- {}\n",
            skills
                .iter()
                .map(|k| k.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
        s.push_str("\n## Skills (read one with `sb skill show <name>`)\n\n");
        let all_cost: usize = full.iter().map(|l| tokens(l)).sum();
        if budget.is_none() {
            for k in &skills {
                s.push_str(&format!("- {}: {}\n", k.name, k.description));
            }
        } else if left.is_none_or(|l| all_cost <= l) {
            full.iter().for_each(|l| s.push_str(l));
        } else {
            s.push_str(&names);
        }
    }
    Ok(s)
}

/// The general rules and, for a repository, its own rules.
pub fn rules_text(home: &Home, d: Option<&Dossier>) -> String {
    let general = home.rules();
    let mut s = String::from("## General rules\n\n");
    s.push_str(general.trim());
    s.push('\n');
    if let Some(d) = d {
        s.push_str(&format!("\n## Rules of {}\n\n", d.meta.identity));
        let r = d.rules();
        if r.trim().is_empty() {
            s.push_str("(none: set them with `sb rules set`)\n");
        } else {
            s.push_str(r.trim());
            s.push('\n');
        }
    }
    s
}

pub fn task_list_text(tasks: &[Task]) -> String {
    if tasks.is_empty() {
        return "No tasks.\n".into();
    }
    tasks
        .iter()
        .map(|t| {
            let waits: Vec<String> = t
                .blocked_by
                .iter()
                .filter(|b| tasks.iter().any(|x| x.id == **b && x.is_open()))
                .map(|b| format!("#{b}"))
                .collect();
            let mut line = t.summary();
            if !waits.is_empty() {
                line.push_str(&format!(" (waits for {})", waits.join(", ")));
            }
            if let (Some(by), true) = (&t.claimed_by, t.is_claimed(crate::date::now_secs())) {
                line.push_str(&format!(" (held by {by})"));
            }
            line.push('\n');
            line
        })
        .collect()
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
    if let Some(accept) = &t.accept {
        s.push_str(&format!("Acceptance command: {accept}\n"));
    }
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
            .decisions()?
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
    Ok(format_hits(hits, query))
}

fn format_hits(hits: Vec<String>, query: &str) -> String {
    if hits.is_empty() {
        return format!(
            "Nothing found for '{query}'.
"
        );
    }
    let total = hits.len();
    let mut s: String = hits
        .into_iter()
        .take(SEARCH_LIMIT)
        .map(|h| {
            h + "
"
        })
        .collect();
    if total > SEARCH_LIMIT {
        s.push_str(&format!(
            "... {} more results; narrow the search
",
            total - SEARCH_LIMIT
        ));
    }
    s
}

/// Ranked search (SQLite FTS5, BM25). If the index is damaged it is rebuilt once; if it still
/// fails, the plain substring search answers instead.
pub fn search(home: &Home, dossiers: &[Dossier], query: &str) -> Result<String> {
    if query.trim().is_empty() {
        return Err(anyhow!("the search text is empty"));
    }
    for attempt in 0..2 {
        match crate::index::search(home, dossiers, query) {
            Ok(mut hits) => {
                for d in dossiers {
                    if let Ok(found) = crate::kb::search(d, query, None, 3) {
                        hits.extend(
                            found
                                .iter()
                                .map(|h| format!("{} {}", d.meta.identity, crate::kb::hit_line(h))),
                        );
                    }
                }
                return Ok(format_hits(hits, query));
            }
            Err(_) if attempt == 0 => {
                let _ = crate::index::reset(home);
            }
            Err(_) => break,
        }
    }
    search_text(dossiers, query)
}

pub(crate) fn read_link_file(path: &Path) -> Result<Option<String>> {
    if path.is_symlink() {
        return Err(anyhow!(
            "refusing to replace symbolic link {}",
            path.display()
        ));
    }
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Writes the SecondBrain block into AGENTS.md and the pointer files that are asked for.
pub fn link_files(root: &Path, rules: &str, files: &[String]) -> Result<Vec<String>> {
    let mut msgs = Vec::new();
    for f in files {
        match f.trim().to_lowercase().as_str() {
            "agents" => {
                let path = root.join("AGENTS.md");
                let old = read_link_file(&path)?.unwrap_or_default();
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
                match read_link_file(&path)? {
                    None => {
                        write_atomic(&path, "@AGENTS.md\n")?;
                        msgs.push(format!("created {} (points to AGENTS.md)", path.display()));
                    }
                    Some(text) if text.contains("@AGENTS.md") => {}
                    Some(_) => msgs.push(format!(
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

/// Records a checkout without replacing its existing dossier or private notes.
pub fn link_checkout(
    home: &Home,
    folder: &Path,
    files: &[String],
    init_home: bool,
) -> Result<String> {
    let (root, identity) = checkout(folder)?;
    if init_home && !home.is_initialized() {
        home.init()?;
    }
    home.require()?;
    let root_path = Path::new(&root);
    let (dossier, created) = match home.find_checkout(&identity, root_path)? {
        Some(dossier) => (dossier, false),
        None => home.find_or_create(&identity)?,
    };
    dossier.with_lock(|| {
        let mut dossier = Dossier::load(&dossier.dir)?;
        if dossier.add_path(&root) {
            dossier.save_meta()?;
        }
        let mut result = format!("{} {identity}\n", if created { "Added" } else { "Already added:" });
        if !files.is_empty() {
            for message in link_files(root_path, &home.rules(), files)? {
                result.push_str(&format!("- {message}\n"));
            }
        }
        result.push_str(&format!("Dossier: {}\n", dossier.dir.display()));
        if dossier.context().trim().is_empty() {
            result.push_str("Initial context is empty. Use `sb guide onboarding` or `get_guide` with topic `onboarding` to analyze the checkout and save a starting dossier.\n");
        }
        Ok(result)
    })
}

/// Points an existing local dossier (a repository without a GitHub remote) at the folder it
/// moved to. The identity of a local repository follows its folder, so a moved or renamed
/// checkout would otherwise get a new, empty dossier. Folders that no longer exist are forgotten.
pub fn relink(home: &Home, spec: &str, folder: &Path) -> Result<String> {
    home.require()?;
    let (root, identity) = checkout(folder)?;
    let root_path = Path::new(&root);
    let target = home.resolve_repo(Some(spec), folder)?;
    if !target.meta.identity.starts_with("local/") {
        bail!(
            "{} has a GitHub remote; its dossier follows the remote, so there is nothing to relink",
            target.meta.identity
        );
    }
    if let Some(current) = home.find_checkout(&identity, root_path)?
        && current.dir != target.dir
    {
        let empty = current.context().trim().is_empty() && current.tasks()?.is_empty();
        if !empty {
            bail!(
                "this folder already belongs to {} and that dossier holds work; run `sb unlink` here first, or relink that one",
                current.meta.identity
            );
        }
        current.with_lock(|| {
            let mut other = Dossier::load(&current.dir)?;
            other.remove_path(&root);
            other.save_meta()
        })?;
    }
    let marker = git::root_commit(root_path);
    if let (Some(recorded), Some(actual)) = (&target.meta.root, &marker)
        && recorded != actual
    {
        bail!(
            "this folder has a different Git history than the one recorded for {}; it looks like another repository",
            target.meta.identity
        );
    }
    target.with_lock(|| {
        let mut dossier = Dossier::load(&target.dir)?;
        if marker.is_some() {
            dossier.meta.root = marker.clone();
        }
        let before = dossier.meta.paths.clone();
        for old in before {
            if !Path::new(&old).is_dir() {
                dossier.remove_path(&old);
            }
        }
        dossier.add_path(&root);
        dossier.save_meta()?;
        Ok(format!(
            "Relinked {} to {root}. Its context, decisions and tasks follow this folder; run `sb start` to check.
",
            dossier.meta.identity
        ))
    })
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

/// Compare or refresh the managed block in explicit user-level instruction files.
pub fn sync_agent_rules(home: &Home, files: &[PathBuf], check: bool) -> Result<(String, bool)> {
    let body = block::body(&home.rules());
    let expected = block::directive_version(&body).unwrap_or("unknown");
    let mut text = format!("Expected directive version: {expected}\n");
    let mut mismatch = false;
    for path in files {
        let old = read_link_file(path)?;
        let current = old.as_deref().unwrap_or_default();
        if !block::markers_valid(current) {
            return Err(anyhow!("invalid SecondBrain markers in {}", path.display()));
        }
        let updated = block::upsert(current, &body);
        if updated == current {
            text.push_str(&format!("Aligned {} [{expected}]\n", path.display()));
        } else if check {
            mismatch = true;
            let actual = block::directive_version(current).unwrap_or("unversioned");
            text.push_str(&format!("Out of sync {} [{actual}]\n", path.display()));
        } else {
            if let Some(old) = old {
                let mut backup = path.as_os_str().to_os_string();
                backup.push(".sb-backup");
                let backup = PathBuf::from(backup);
                if read_link_file(&backup)?.is_none() {
                    write_atomic(&backup, &old)?;
                }
            }
            write_atomic(path, &updated)?;
            text.push_str(&format!("Updated {} [{expected}]\n", path.display()));
        }
    }
    Ok((text, mismatch))
}

/// The checkout root of `path` and its identity.
pub fn checkout(path: &Path) -> Result<(String, String)> {
    let root = git::repo_root(path)
        .ok_or_else(|| anyhow!("{} is not inside a Git repository", path.display()))?;
    Ok((native_path(&root), git::identity(&root)))
}

/// The path as text with the platform's separator (Git reports forward slashes on Windows).
pub fn native_path(path: &Path) -> String {
    let s = path.display().to_string();
    if cfg!(windows) {
        s.replace('/', "\\")
    } else {
        s
    }
}
