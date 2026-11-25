//! A task is one Markdown file: a small front matter block, then a free Markdown body.
//!
//! ```text
//! ---
//! id: 12
//! title: "Fix the login redirect"
//! status: todo
//! priority: 2
//! needs_user: true
//! created: 2026-11-25
//! updated: 2026-11-25
//! ---
//!
//! Free Markdown body.
//! ```

use anyhow::{Context as _, Result, anyhow, bail};
use serde::Serialize;
use std::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Todo,
    Doing,
    Blocked,
    Done,
}

impl Status {
    pub fn parse(value: &str) -> Result<Status> {
        match value.trim().to_ascii_lowercase().as_str() {
            "todo" | "open" => Ok(Status::Todo),
            "doing" | "in_progress" | "in-progress" => Ok(Status::Doing),
            "blocked" => Ok(Status::Blocked),
            "done" | "closed" => Ok(Status::Done),
            other => bail!("unknown status '{other}' (use todo, doing, blocked or done)"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Todo => "todo",
            Status::Doing => "doing",
            Status::Blocked => "blocked",
            Status::Done => "done",
        }
    }

    /// Sort order for open work: what is in progress first, blocked work last.
    pub fn rank(self) -> u8 {
        match self {
            Status::Doing => 0,
            Status::Todo => 1,
            Status::Blocked => 2,
            Status::Done => 3,
        }
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Task {
    pub id: u32,
    pub title: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<u8>,
    pub needs_user: bool,
    pub created: String,
    pub updated: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub legacy_id: Option<String>,
    pub body: String,
    /// Front matter keys this version does not know, kept as written.
    #[serde(skip)]
    pub extra: Vec<(String, String)>,
}

impl Task {
    pub fn new(id: u32, title: &str, today: &str) -> Task {
        Task {
            id,
            title: one_line(title),
            status: Status::Todo,
            priority: None,
            needs_user: false,
            created: today.to_string(),
            updated: today.to_string(),
            legacy_id: None,
            body: String::new(),
            extra: Vec::new(),
        }
    }

    pub fn is_open(&self) -> bool {
        self.status != Status::Done
    }

    /// One line for lists: `#12 [todo] P2 Title (needs you)`.
    pub fn summary(&self) -> String {
        let priority = self.priority.map(|p| format!(" P{p}")).unwrap_or_default();
        let needs = if self.needs_user { " (needs you)" } else { "" };
        format!(
            "#{} [{}]{} {}{}",
            self.id, self.status, priority, self.title, needs
        )
    }

    pub fn to_markdown(&self) -> String {
        let mut s = String::from("---\n");
        s.push_str(&format!("id: {}\n", self.id));
        s.push_str(&format!("title: {}\n", quote(&self.title)));
        s.push_str(&format!("status: {}\n", self.status));
        if let Some(p) = self.priority {
            s.push_str(&format!("priority: {p}\n"));
        }
        if self.needs_user {
            s.push_str("needs_user: true\n");
        }
        s.push_str(&format!("created: {}\n", self.created));
        s.push_str(&format!("updated: {}\n", self.updated));
        if let Some(l) = &self.legacy_id {
            s.push_str(&format!("legacy_id: {}\n", quote(l)));
        }
        for (k, v) in &self.extra {
            s.push_str(&format!("{k}: {v}\n"));
        }
        s.push_str("---\n");
        let body = self.body.trim();
        if !body.is_empty() {
            s.push('\n');
            s.push_str(body);
            s.push('\n');
        }
        s
    }

    pub fn parse(text: &str) -> Result<Task> {
        let text = text.replace("\r\n", "\n");
        let text = text.trim_start_matches('\u{feff}');
        let rest = text
            .strip_prefix("---\n")
            .ok_or_else(|| anyhow!("the file does not start with a '---' front matter line"))?;
        let (front, body) = match rest.find("\n---\n") {
            Some(i) => (&rest[..i], &rest[i + 5..]),
            None => match rest.strip_suffix("\n---") {
                Some(front) => (front, ""),
                None => bail!("the front matter has no closing '---' line"),
            },
        };

        let mut id = None;
        let mut title = None;
        let mut task = Task::new(0, "", "");
        for line in front.lines() {
            if line.trim().is_empty() {
                continue;
            }
            let (key, raw) = line
                .split_once(':')
                .ok_or_else(|| anyhow!("front matter line without ':': {line}"))?;
            let key = key.trim();
            let raw = raw.trim();
            let value = unquote(raw).with_context(|| format!("value of '{key}'"))?;
            match key {
                "id" => {
                    id = Some(
                        value
                            .parse::<u32>()
                            .with_context(|| format!("id '{value}'"))?,
                    )
                }
                "title" => title = Some(one_line(&value)),
                "status" => task.status = Status::parse(&value)?,
                "priority" => {
                    task.priority = if value.is_empty() {
                        None
                    } else {
                        Some(parse_priority(&value)?)
                    }
                }
                "needs_user" => task.needs_user = parse_bool(&value)?,
                "created" => task.created = value,
                "updated" => task.updated = value,
                "legacy_id" => task.legacy_id = (!value.is_empty()).then_some(value),
                _ => task.extra.push((key.to_string(), raw.to_string())),
            }
        }
        task.id = id.ok_or_else(|| anyhow!("the front matter has no 'id'"))?;
        task.title = title.ok_or_else(|| anyhow!("the front matter has no 'title'"))?;
        task.body = body.trim().to_string();
        Ok(task)
    }
}

pub fn parse_priority(value: &str) -> Result<u8> {
    let v = value.trim().trim_start_matches(['p', 'P']);
    match v.parse::<u8>() {
        Ok(p @ 1..=4) => Ok(p),
        _ => bail!("priority '{value}' must be 1 (highest) to 4"),
    }
}

fn parse_bool(value: &str) -> Result<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" => Ok(true),
        "false" | "no" | "" => Ok(false),
        other => bail!("'{other}' is not true or false"),
    }
}

/// Collapses line breaks so a title stays on one front matter line.
pub fn one_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn quote(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| format!("\"{value}\""))
}

fn unquote(raw: &str) -> Result<String> {
    if raw.starts_with('"') {
        Ok(serde_json::from_str::<String>(raw)?)
    } else if raw.len() >= 2 && raw.starts_with('\'') && raw.ends_with('\'') {
        Ok(raw[1..raw.len() - 1].replace("''", "'"))
    } else {
        Ok(raw.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_keeps_every_field() {
        let mut t = Task::new(7, "Fix \"quotes\": and\nnew lines", "2026-11-25");
        t.status = Status::Blocked;
        t.priority = Some(2);
        t.needs_user = true;
        t.legacy_id = Some("TASK-545".into());
        t.body = "## Notes\n\nSome *body*.".into();
        t.extra.push(("owner".into(), "me".into()));
        let parsed = Task::parse(&t.to_markdown()).unwrap();
        assert_eq!(parsed, t);
        assert_eq!(parsed.title, "Fix \"quotes\": and new lines");
    }

    #[test]
    fn parses_hand_written_crlf_files() {
        let text = "---\r\nid: 3\r\ntitle: Plain title\r\nstatus: in_progress\r\npriority: P1\r\n---\r\n\r\nBody\r\n";
        let t = Task::parse(text).unwrap();
        assert_eq!((t.id, t.status, t.priority), (3, Status::Doing, Some(1)));
        assert_eq!(t.title, "Plain title");
        assert_eq!(t.body, "Body");
    }

    #[test]
    fn front_matter_only_and_errors() {
        assert!(Task::parse("---\nid: 1\ntitle: x\n---").is_ok());
        assert!(Task::parse("no front matter").is_err());
        assert!(Task::parse("---\ntitle: x\n---\n").is_err());
        assert!(Task::parse("---\nid: 1\ntitle: x\npriority: 9\n---\n").is_err());
    }
}
