//! `sb import` and `sb export`: bring a repository's existing agent instructions into the
//! dossier, and write a dossier out in plain formats.
//!
//! Import only reads. It never changes a file in the repository, skips the SecondBrain block and
//! files that only point at AGENTS.md, refuses text that looks like a secret or personal data, and
//! adds each file's text to the repository rules once. Export never writes into a repository.

use crate::block;
use crate::check::{self, Kind, Scope};
use crate::store::{Dossier, Home};
use anyhow::{Context as _, Result, bail};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

/// Instruction files an import looks at, relative to the repository root.
const FILES: &[&str] = &[
    "AGENTS.md",
    "CLAUDE.md",
    "GEMINI.md",
    ".github/copilot-instructions.md",
    ".cursorrules",
];

/// Rule files of Cursor (`.cursor/rules/*.md|mdc`), newest layout first.
fn cursor_rules(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(root.join(".cursor").join("rules"))
        .map(|d| {
            d.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.extension()
                        .and_then(|e| e.to_str())
                        .is_some_and(|e| e == "md" || e == "mdc")
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// The text worth importing: the file without the SecondBrain block, comments-only lines and
/// bare `@file` pointers; empty when nothing is left.
fn useful_text(raw: &str) -> String {
    let text = raw.replace("\r\n", "\n");
    let text = block::remove(&text).unwrap_or(text);
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| {
            let t = l.trim();
            !(t.starts_with('@') && !t.contains(' '))
        })
        .collect();
    let body = kept.join("\n");
    // Front matter of a Cursor rule (`---` ... `---`) is not content.
    let body = match body
        .strip_prefix("---\n")
        .and_then(|r| r.split_once("\n---\n"))
    {
        Some((_, rest)) => rest.to_string(),
        None => body,
    };
    let has_words = body
        .lines()
        .any(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'));
    if has_words {
        body.trim().to_string()
    } else {
        String::new()
    }
}

/// Imports what the repository at `root` already tells agents, as repository rules.
pub fn import(d: &Dossier, root: &Path, dry_run: bool) -> Result<String> {
    let mut candidates: Vec<PathBuf> = FILES.iter().map(|f| root.join(f)).collect();
    candidates.extend(cursor_rules(root));
    let mut rules = d.rules();
    let mut out = String::new();
    let mut imported = 0;
    for path in candidates.into_iter().filter(|p| p.is_file()) {
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let raw = fs::read_to_string(&path).with_context(|| format!("reading {rel}"))?;
        let text = useful_text(&raw);
        if text.is_empty() {
            out.push_str(&format!("- {rel}: nothing to import\n"));
            continue;
        }
        if rules.contains(&text) {
            out.push_str(&format!("- {rel}: already in the rules\n"));
            continue;
        }
        let scope = Scope::default();
        let flagged: Vec<String> = text
            .lines()
            .enumerate()
            .flat_map(|(i, l)| check::scan_line(&rel, i + 1, l, "working", &scope))
            .filter(|f| matches!(f.kind, Kind::Secret | Kind::Personal))
            .map(|f| format!("line {} ({})", f.line, f.rule))
            .collect();
        if !flagged.is_empty() {
            out.push_str(&format!(
                "- {rel}: skipped, it looks like it holds secrets or personal data ({}); clean it and import again\n",
                flagged.join(", ")
            ));
            continue;
        }
        imported += 1;
        out.push_str(&format!(
            "- {rel}: {} line(s) {}\n",
            text.lines().count(),
            if dry_run {
                "would be imported"
            } else {
                "imported"
            }
        ));
        if !dry_run {
            if !rules.trim().is_empty() {
                rules = format!("{}\n\n", rules.trim_end());
            }
            rules.push_str(&format!("## Imported from {rel}\n\n{text}\n"));
        }
    }
    if out.is_empty() {
        out.push_str("No instruction files found (AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, .cursor/rules, copilot-instructions.md).\n");
    }
    if imported > 0 && !dry_run {
        d.set_rules(&rules)?;
        out.push_str(&format!(
            "Added to the rules of {}; nothing in the repository changed.\n",
            d.meta.identity
        ));
    }
    Ok(out)
}

fn dossier_json(d: &Dossier) -> Result<serde_json::Value> {
    Ok(json!({
        "identity": d.meta.identity,
        "context": d.context(),
        "rules": d.rules(),
        "decisions": d.decisions()?,
        "tasks": d.tasks()?,
    }))
}

fn dossier_markdown(d: &Dossier) -> Result<String> {
    let mut s = format!("# {}\n\n## Context\n\n", d.meta.identity);
    let context = d.context();
    s.push_str(if context.trim().is_empty() {
        "(empty)"
    } else {
        context.trim()
    });
    s.push('\n');
    let rules = d.rules();
    if !rules.trim().is_empty() {
        s.push_str(&format!("\n## Rules\n\n{}\n", rules.trim()));
    }
    let decisions = d.decisions()?;
    if !decisions.is_empty() {
        s.push_str("\n## Decisions\n\n");
        for line in decisions {
            s.push_str(&format!("{line}\n"));
        }
    }
    s.push_str("\n## Tasks\n");
    for t in d.tasks()? {
        s.push_str(&format!("\n### {}\n\n", t.summary()));
        s.push_str(&format!("created {}, updated {}\n", t.created, t.updated));
        if !t.blocked_by.is_empty() {
            let ids: Vec<String> = t.blocked_by.iter().map(|b| format!("#{b}")).collect();
            s.push_str(&format!("waits for {}\n", ids.join(", ")));
        }
        if !t.body.trim().is_empty() {
            s.push_str(&format!("\n{}\n", t.body.trim()));
        }
    }
    Ok(s)
}

/// Refuses a path inside a Git repository (the data folder itself excepted).
pub fn ensure_outside_repo(home: &Home, path: &Path) -> Result<()> {
    let mut probe = path;
    while !probe.exists() {
        match probe.parent() {
            Some(p) if !p.as_os_str().is_empty() => probe = p,
            _ => break,
        }
    }
    let folder = if probe.is_dir() {
        Some(probe)
    } else {
        probe.parent()
    };
    if folder.is_some_and(|f| crate::git::repo_root(f).is_some()) && !path.starts_with(&home.root) {
        bail!(
            "{} is inside a Git repository; the dossier must not be written there",
            path.display()
        );
    }
    Ok(())
}

/// A dossier (or several) as Markdown or JSON.
pub fn export(dossiers: &[Dossier], format: &str) -> Result<String> {
    match format.to_ascii_lowercase().as_str() {
        "md" | "markdown" => {
            let parts: Result<Vec<String>> = dossiers.iter().map(dossier_markdown).collect();
            Ok(parts?.join("\n---\n\n"))
        }
        "json" => {
            let all: Result<Vec<serde_json::Value>> = dossiers.iter().map(dossier_json).collect();
            let all = all?;
            let value = if all.len() == 1 {
                all.into_iter().next().unwrap_or_default()
            } else {
                json!(all)
            };
            Ok(serde_json::to_string_pretty(&value)? + "\n")
        }
        other => bail!("unknown format '{other}' (use md or json)"),
    }
}

#[cfg(test)]
mod tests {
    use super::useful_text;

    #[test]
    fn useful_text_drops_the_block_pointers_and_front_matter() {
        assert_eq!(useful_text("@AGENTS.md\n"), "");
        let with_block = format!(
            "Be brief.\n\n{}\n## SecondBrain\nx\n{}\n",
            crate::block::BEGIN,
            crate::block::END
        );
        assert_eq!(useful_text(&with_block), "Be brief.");
        assert_eq!(useful_text("# Title only\n"), "");
        assert_eq!(
            useful_text("---\nalwaysApply: true\n---\nUse tabs.\n"),
            "Use tabs."
        );
    }
}
