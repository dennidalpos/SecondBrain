//! Skills kept in SecondBrain: `<data folder>/skills/<name>/SKILL.md`, read by agents on demand.

use crate::store::{Home, write_atomic};
use anyhow::{Result, anyhow, bail};
use std::fs;
use std::path::PathBuf;

pub struct Skill {
    pub name: String,
    pub description: String,
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !name.starts_with('-')
        && !name.ends_with('-')
}

fn dir(home: &Home, name: &str) -> Result<PathBuf> {
    if !valid_name(name) {
        bail!("invalid skill name '{name}': use lowercase letters, digits and hyphens");
    }
    Ok(home.skills_dir().join(name))
}

/// The `description:` value of the front matter, if any.
fn description(text: &str) -> String {
    let mut lines = text.lines();
    if lines.next().map(str::trim) != Some("---") {
        return String::new();
    }
    for line in lines {
        let line = line.trim();
        if line == "---" {
            break;
        }
        if let Some(v) = line.strip_prefix("description:") {
            return v.trim().trim_matches(['"', '\'']).to_string();
        }
    }
    String::new()
}

pub fn list(home: &Home) -> Result<Vec<Skill>> {
    let mut out = Vec::new();
    let root = home.skills_dir();
    if !root.is_dir() {
        return Ok(out);
    }
    for entry in fs::read_dir(&root)? {
        let path = entry?.path();
        let file = path.join("SKILL.md");
        if let (Some(name), Ok(text)) = (
            path.file_name().and_then(|n| n.to_str()),
            fs::read_to_string(&file),
        ) {
            out.push(Skill {
                name: name.to_string(),
                description: description(&text),
            });
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

pub fn list_text(home: &Home) -> Result<String> {
    let all = list(home)?;
    if all.is_empty() {
        return Ok("No skills yet: add one with `sb skill add <name> --file SKILL.md`.\n".into());
    }
    Ok(all
        .iter()
        .map(|s| format!("{}  {}\n", s.name, s.description))
        .collect())
}

pub fn show(home: &Home, name: &str) -> Result<String> {
    let file = dir(home, name)?.join("SKILL.md");
    fs::read_to_string(&file).map_err(|_| anyhow!("unknown skill '{name}'; see `sb skill list`"))
}

/// Stores or replaces a skill; the text should be a SKILL.md with `name` and `description` front matter.
pub fn add(home: &Home, name: &str, text: &str) -> Result<String> {
    home.require()?;
    let d = dir(home, name)?;
    let text = text.replace("\r\n", "\n");
    if text.trim().is_empty() {
        bail!("the skill text is empty");
    }
    let existed = d.join("SKILL.md").exists();
    write_atomic(&d.join("SKILL.md"), &format!("{}\n", text.trim_end()))?;
    let mut s = format!(
        "{} skill {name}\n",
        if existed { "Replaced" } else { "Added" }
    );
    if description(&text).is_empty() {
        s.push_str("Note: no `description:` in the front matter; agents list skills by it.\n");
    }
    Ok(s)
}

pub fn remove(home: &Home, name: &str) -> Result<String> {
    let d = dir(home, name)?;
    if !d.join("SKILL.md").is_file() {
        bail!("unknown skill '{name}'; see `sb skill list`");
    }
    fs::remove_dir_all(&d)?;
    Ok(format!("Removed skill {name}\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_descriptions() {
        assert!(valid_name("review-checklist"));
        assert!(!valid_name("../x"));
        assert!(!valid_name("Up"));
        assert!(!valid_name("-a"));
        assert_eq!(
            description("---\nname: a\ndescription: \"Does a thing\"\n---\nbody"),
            "Does a thing"
        );
        assert_eq!(description("no front matter"), "");
    }
}
