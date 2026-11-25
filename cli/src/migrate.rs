//! Imports the open tasks exported from SecondBrain 4 (`open-tasks-*.json`).
//! Running it twice is safe: a task whose v4 id is already in the dossier is skipped.

use crate::date;
use crate::git;
use crate::ops;
use crate::store::Home;
use crate::task::{Status, Task, one_line, parse_priority};
use anyhow::{Context as _, Result, anyhow};
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::Path;

const TITLE_MAX: usize = 100;

pub fn run(home: &Home, file: &Path, link: bool) -> Result<String> {
    home.require()?;
    let text = fs::read_to_string(file).with_context(|| format!("reading {}", file.display()))?;
    let export: Value = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .with_context(|| format!("parsing {}", file.display()))?;
    let repos = export["repositories"]
        .as_array()
        .ok_or_else(|| anyhow!("{} has no 'repositories' list", file.display()))?;

    let today = date::today();
    let mut out = String::new();
    let (mut imported_total, mut skipped_total) = (0, 0);
    for repo in repos {
        let exported = repo["identity"]
            .as_str()
            .ok_or_else(|| anyhow!("a repository in the export has no identity"))?
            .to_lowercase();
        // The checkout's live identity wins, so `sb add` there finds this dossier later.
        let live = repo["path"]
            .as_str()
            .filter(|p| Path::new(p).is_dir())
            .and_then(|p| git::repo_root(Path::new(p)))
            .map(|root| git::identity(&root));
        let identity = live.unwrap_or(exported);
        let (mut dossier, _) = home.find_or_create(&identity)?;
        if let Some(path) = repo["path"].as_str().filter(|p| !p.is_empty())
            && dossier.add_path(path)
        {
            dossier.save_meta()?;
        }
        let mut known: HashSet<String> = dossier
            .tasks()?
            .into_iter()
            .filter_map(|t| t.legacy_id)
            .collect();
        let mut next = dossier.next_id()?;
        let (mut imported, mut skipped) = (0, 0);
        let items = repo["tasks"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| (t, false));
        let legacy = repo["legacyTasks"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| (t, true));
        for (item, is_legacy) in items.chain(legacy) {
            let legacy_id = text_of(&item["id"]).filter(|s| !s.is_empty());
            if let Some(l) = &legacy_id
                && known.contains(l)
            {
                skipped += 1;
                continue;
            }
            let task = convert(item, is_legacy, next, legacy_id.clone(), &today);
            dossier.save_task(&task)?;
            if let Some(l) = legacy_id {
                known.insert(l);
            }
            next += 1;
            imported += 1;
        }
        out.push_str(&format!(
            "{identity}: {imported} imported, {skipped} already there\n"
        ));
        if link {
            for path in dossier.meta.paths.clone() {
                if Path::new(&path).is_dir() {
                    for m in ops::link_files(
                        Path::new(&path),
                        &home.rules(),
                        &["agents".into(), "claude".into()],
                    )? {
                        out.push_str(&format!("  {m}\n"));
                    }
                }
            }
        }
        imported_total += imported;
        skipped_total += skipped;
    }
    out.push_str(&format!(
        "{imported_total} tasks imported, {skipped_total} skipped, {} repositories.\n",
        repos.len()
    ));
    Ok(out)
}

fn convert(item: &Value, is_legacy: bool, id: u32, legacy_id: Option<String>, today: &str) -> Task {
    let description = text_of(&item["description"])
        .or_else(|| {
            if is_legacy {
                text_of(&item["task"])
            } else {
                None
            }
        })
        .unwrap_or_default();
    let raw_title = text_of(&item["title"])
        .or_else(|| text_of(&item["task"]))
        .or_else(|| legacy_id.clone())
        .unwrap_or_else(|| format!("Task {id}"));
    let mut title = one_line(&raw_title);
    loop {
        let stripped = strip_number_prefix(&title);
        if stripped == title {
            break;
        }
        title = stripped;
    }
    let title = shorten(&title);

    let mut t = Task::new(id, &title, today);
    t.legacy_id = legacy_id;
    t.status = match text_of(&item["status"]).as_deref().map(Status::parse) {
        Some(Ok(s)) => s,
        _ => Status::Todo,
    };
    t.priority = text_of(&item["priority"]).and_then(|p| priority_of(&p));
    t.needs_user = item["execution"].as_str() == Some("user_required");

    let mut body = Vec::new();
    if !description.is_empty() && one_line(&description) != title {
        body.push(description.trim().to_string());
    }
    if one_line(&raw_title) != title && !description.contains(raw_title.trim()) {
        body.push(format!("Full v4 title: {}", one_line(&raw_title)));
    }
    let acceptance = list_of(&item["acceptance"])
        .into_iter()
        .chain(list_of(&item["acceptance_criteria"]));
    let acceptance: Vec<String> = acceptance.collect();
    if !acceptance.is_empty() {
        body.push(format!("## Acceptance\n\n{}", bullets(&acceptance)));
    }
    let mut blockers: Vec<String> = Vec::new();
    for v in [
        &item["blocked_by"],
        &item["extensions"]["original"]["blocked_by"],
    ] {
        blockers.extend(text_of(v).filter(|s| !s.is_empty()));
    }
    blockers.extend(list_of(&item["extensions"]["prerequisites"]));
    blockers.dedup();
    if !blockers.is_empty() {
        body.push(format!("## Blocked by\n\n{}", bullets(&blockers)));
    }
    let deps = list_of(&item["dependencies"]);
    if !deps.is_empty() {
        body.push(format!("## Depends on (v4 ids)\n\n{}", bullets(&deps)));
    }
    t.body = body.join("\n\n");
    t
}

fn priority_of(value: &str) -> Option<u8> {
    let v = value.trim().to_lowercase();
    match v.as_str() {
        "critical" | "urgent" | "high" => Some(1),
        "medium" | "normal" => Some(2),
        "low" => Some(3),
        _ => parse_priority(&v).ok().or_else(|| {
            v.trim_start_matches('p')
                .parse::<u32>()
                .ok()
                .map(|n| n.clamp(1, 4) as u8)
        }),
    }
}

/// `#123 - Title`, `#002 — Title` and `#7: Title` become `Title`.
fn strip_number_prefix(title: &str) -> String {
    if let Some(rest) = title.strip_prefix('#') {
        let digits = rest.chars().take_while(char::is_ascii_digit).count();
        if digits > 0 {
            let tail = &rest[digits..];
            let after = tail.trim_start_matches([' ', '-', '—', '–', ':']);
            let separator = &tail[..tail.len() - after.len()];
            if separator.contains(['-', '—', '–', ':']) && !after.is_empty() {
                return after.trim().to_string();
            }
        }
    }
    title.to_string()
}

fn shorten(title: &str) -> String {
    if title.chars().count() <= TITLE_MAX {
        return title.to_string();
    }
    let cut: String = title.chars().take(TITLE_MAX).collect();
    let cut = match cut.rfind(' ') {
        Some(i) if i > TITLE_MAX / 2 => cut[..i].to_string(),
        _ => cut,
    };
    format!("{}...", cut.trim_end_matches([',', ';', ':', '.', ' ']))
}

fn text_of(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

fn list_of(v: &Value) -> Vec<String> {
    let Some(items) = v.as_array() else {
        return text_of(v)
            .filter(|s| !s.trim().is_empty())
            .into_iter()
            .collect();
    };
    items
        .iter()
        .filter_map(|i| match i {
            Value::Object(o) => ["text", "description", "criterion", "title", "id"]
                .iter()
                .find_map(|k| o.get(*k).and_then(text_of))
                .or_else(|| Some(i.to_string())),
            other => text_of(other),
        })
        .map(|s| one_line(&s))
        .filter(|s| !s.is_empty())
        .collect()
}

fn bullets(items: &[String]) -> String {
    items
        .iter()
        .map(|i| format!("- {i}"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_a_v4_task() {
        let item = json!({
            "id": "TASK-545", "title": "#545 - Close Dependabot #13", "status": "in_progress",
            "priority": "P2", "execution": "user_required", "description": "Wait for Tauri.",
            "acceptance": ["Alert closed", {"text": "CI green"}], "dependencies": ["TASK-1"],
            "extensions": {"original": {"blocked_by": "needs GTK4"}}
        });
        let t = convert(&item, false, 4, Some("TASK-545".into()), "2026-11-25");
        assert_eq!(t.title, "Close Dependabot #13");
        assert_eq!(
            (t.id, t.status, t.priority, t.needs_user),
            (4, Status::Doing, Some(2), true)
        );
        assert!(t.body.starts_with("Wait for Tauri."));
        assert!(
            t.body.contains("- CI green")
                && t.body.contains("- needs GTK4")
                && t.body.contains("- TASK-1")
        );
    }

    #[test]
    fn legacy_task_uses_task_text_and_shortens() {
        let long = "Verify by hand on every device that the error log has no overlapping columns and that the support page opens without a modal";
        let item = json!({"id": "repo-x", "task": long, "status": "planned", "priority": 7,
            "acceptance_criteria": ["Done when checked"]});
        let t = convert(&item, true, 1, Some("repo-x".into()), "2026-11-25");
        assert!(t.title.ends_with("...") && t.title.chars().count() <= TITLE_MAX + 3);
        assert_eq!((t.status, t.priority), (Status::Todo, Some(4)));
        assert!(t.body.starts_with(long));
        assert_eq!(strip_number_prefix("#002 — Fix lint"), "Fix lint");
        assert_eq!(strip_number_prefix("#7: Fix"), "Fix");
        assert_eq!(strip_number_prefix("#545 - Close #13"), "Close #13");
        assert_eq!(strip_number_prefix("#hashtag title"), "#hashtag title");
        assert_eq!(
            strip_number_prefix("#021 residuo: tray"),
            "#021 residuo: tray"
        );
        assert_eq!(strip_number_prefix("#12"), "#12");
        assert_eq!(priority_of("high"), Some(1));
        assert_eq!(priority_of(""), None);
    }
}
