//! A task is one Markdown file: a small front matter block, then a free Markdown body.
//!
//! ```text
//! ---
//! id: 12
//! title: "Fix the login redirect"
//! status: todo
//! priority: 2
//! needs_user: true
//! blocked_by: 3, 5
//! accept: "cargo test"
//! claimed_by: nightly
//! claimed_until: 1795000000
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
    #[serde(skip)]
    pub(crate) key: Option<String>,
    pub title: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<u8>,
    pub needs_user: bool,
    /// Tasks that must be done before this one can start.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub blocked_by: Vec<u32>,
    #[serde(skip)]
    pub(crate) blocker_keys: Vec<String>,
    /// A command that must exit 0 in the repository before an unattended run marks the task done.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    /// Who holds the task, and until when (Unix seconds); an expired lease is free again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_until: Option<u64>,
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
            key: None,
            title: one_line(title),
            status: Status::Todo,
            priority: None,
            needs_user: false,
            blocked_by: Vec::new(),
            blocker_keys: Vec::new(),
            accept: None,
            claimed_by: None,
            claimed_until: None,
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

    /// True while a claim is held (the lease has not run out at `now`).
    pub fn is_claimed(&self, now: u64) -> bool {
        self.claimed_until.is_some_and(|u| u > now)
    }

    pub(crate) fn require_claim_by(&self, by: &str) -> anyhow::Result<()> {
        let holder = one_line(by);
        if self.status != Status::Doing
            || !self.is_claimed(crate::date::now_secs())
            || self.claimed_by.as_deref() != Some(&holder)
        {
            anyhow::bail!("task #{} has no active claim held by {holder}", self.id);
        }
        Ok(())
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
        if let Some(key) = &self.key {
            s.push_str(&format!("task_key: {}\n", quote(key)));
        }
        s.push_str(&format!("title: {}\n", quote(&self.title)));
        s.push_str(&format!("status: {}\n", self.status));
        if let Some(p) = self.priority {
            s.push_str(&format!("priority: {p}\n"));
        }
        if self.needs_user {
            s.push_str("needs_user: true\n");
        }
        if !self.blocked_by.is_empty() {
            let ids: Vec<String> = self.blocked_by.iter().map(u32::to_string).collect();
            s.push_str(&format!("blocked_by: {}\n", ids.join(", ")));
        }
        if !self.blocker_keys.is_empty() {
            s.push_str(&format!("blocker_keys: {}\n", self.blocker_keys.join(", ")));
        }
        if let Some(a) = &self.accept {
            s.push_str(&format!("accept: {}\n", quote(a)));
        }
        if let Some(c) = &self.claimed_by {
            s.push_str(&format!("claimed_by: {}\n", quote(c)));
        }
        if let Some(u) = self.claimed_until {
            s.push_str(&format!("claimed_until: {u}\n"));
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
                "task_key" => {
                    if value.is_empty()
                        || !value
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                    {
                        bail!("invalid task_key");
                    }
                    task.key = Some(value);
                }
                "status" => task.status = Status::parse(&value)?,
                "priority" => {
                    task.priority = if value.is_empty() {
                        None
                    } else {
                        Some(parse_priority(&value)?)
                    }
                }
                "needs_user" => task.needs_user = parse_bool(&value)?,
                "blocked_by" => task.blocked_by = parse_ids(&value)?,
                "blocker_keys" => {
                    task.blocker_keys =
                        value.split(',').map(str::trim).map(str::to_owned).collect();
                    if task.blocker_keys.iter().any(|key| {
                        key.is_empty()
                            || !key
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
                    }) {
                        bail!("invalid blocker_keys");
                    }
                }
                "accept" => task.accept = (!value.trim().is_empty()).then_some(value),
                "claimed_by" => task.claimed_by = (!value.is_empty()).then_some(value),
                "claimed_until" => {
                    task.claimed_until = if value.is_empty() {
                        None
                    } else {
                        Some(
                            value
                                .parse::<u64>()
                                .with_context(|| format!("claimed_until '{value}'"))?,
                        )
                    }
                }
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

/// Ids written as `3, 5` or `#3 #5`; empty means none. Duplicates are dropped.
pub fn parse_ids(value: &str) -> Result<Vec<u32>> {
    let mut out: Vec<u32> = Vec::new();
    for part in value
        .split([',', ' ', ';'])
        .filter(|p| !p.trim().is_empty())
    {
        let n = part
            .trim()
            .trim_start_matches('#')
            .parse::<u32>()
            .with_context(|| format!("task id '{part}'"))?;
        if !out.contains(&n) {
            out.push(n);
        }
    }
    Ok(out)
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
        t.blocked_by = vec![2, 5];
        t.accept = Some("cargo test --locked".into());
        t.claimed_by = Some("nightly".into());
        t.claimed_until = Some(1_795_000_000);
        let parsed = Task::parse(&t.to_markdown()).unwrap();
        assert_eq!(parsed, t);
        assert_eq!(parsed.title, "Fix \"quotes\": and new lines");
    }

    #[test]
    fn ids_and_leases() {
        assert_eq!(parse_ids("3, #5 3").unwrap(), vec![3, 5]);
        assert!(parse_ids("").unwrap().is_empty());
        assert!(parse_ids("x").is_err());
        let mut t = Task::new(1, "x", "d");
        assert!(!t.is_claimed(10));
        t.claimed_until = Some(20);
        assert!(t.is_claimed(10) && !t.is_claimed(20));
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
