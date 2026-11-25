//! The SecondBrain home (`~/.secondbrain` or `SB_HOME`) and one dossier per repository:
//!
//! ```text
//! ~/.secondbrain/
//!   rules.md                      shared rules copied into every linked AGENTS.md
//!   repos/github.com--owner--name/
//!     repo.json                   identity and known checkout paths
//!     context.md                  current state, replaced as it changes
//!     decisions.md                one dated line per durable decision
//!     tasks/0012-fix-login.md     one file per task
//! ```

use crate::date;
use crate::git;
use crate::task::{Status, Task};
use anyhow::{Context as _, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const RULES_TEMPLATE: &str = "# Shared rules\n\n<!-- Rules written here are copied into the SecondBrain block of every linked repository's AGENTS.md when you run `sb rules sync`. Keep them short. HTML comments like this one are not copied. -->\n";

/// Writes through a temporary file and a rename, so a crash never leaves half a file.
pub fn write_atomic(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, content).with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// The folder name of a dossier: the identity with `/` written as `--`.
pub fn slug(identity: &str) -> String {
    let mut s = String::new();
    for c in identity.chars() {
        match c {
            '/' => s.push_str("--"),
            c if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') => s.push(c),
            _ => s.push('_'),
        }
    }
    s
}

pub struct Home {
    pub root: PathBuf,
}

impl Home {
    /// `--home`, then `SB_HOME`, then `~/.secondbrain`.
    pub fn resolve(explicit: Option<&Path>) -> Result<Home> {
        if let Some(p) = explicit {
            return Ok(Home {
                root: p.to_path_buf(),
            });
        }
        if let Some(p) = env::var_os("SB_HOME").filter(|v| !v.is_empty()) {
            return Ok(Home {
                root: PathBuf::from(p),
            });
        }
        let vars: &[&str] = if cfg!(windows) {
            &["USERPROFILE", "HOME"]
        } else {
            &["HOME"]
        };
        let home = vars
            .iter()
            .find_map(|v| env::var_os(v).filter(|x| !x.is_empty()))
            .ok_or_else(|| anyhow!("cannot find your home folder; set SB_HOME"))?;
        Ok(Home {
            root: PathBuf::from(home).join(".secondbrain"),
        })
    }

    pub fn repos_dir(&self) -> PathBuf {
        self.root.join("repos")
    }

    pub fn rules_path(&self) -> PathBuf {
        self.root.join("rules.md")
    }

    pub fn is_initialized(&self) -> bool {
        self.repos_dir().is_dir()
    }

    pub fn require(&self) -> Result<()> {
        if !self.is_initialized() {
            bail!(
                "SecondBrain is not set up at {}; run `sb init`",
                self.root.display()
            );
        }
        Ok(())
    }

    /// Creates the folders and the rules template; makes the home a Git repository when Git is installed.
    pub fn init(&self) -> Result<Vec<String>> {
        let mut done = Vec::new();
        if !self.repos_dir().is_dir() {
            fs::create_dir_all(self.repos_dir())?;
            done.push(format!("created {}", self.root.display()));
        }
        if !self.rules_path().exists() {
            write_atomic(&self.rules_path(), RULES_TEMPLATE)?;
            done.push("created rules.md".into());
        }
        let ignore = self.root.join(".gitignore");
        if !ignore.exists() {
            write_atomic(&ignore, "*.tmp\n")?;
        }
        if !self.root.join(".git").exists() && git::available() {
            let ok = Command::new("git")
                .arg("-C")
                .arg(&self.root)
                .args(["init", "-q"])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                done.push(
                    "made it a private Git repository (push it only to a private remote)".into(),
                );
            }
        }
        Ok(done)
    }

    pub fn rules(&self) -> String {
        fs::read_to_string(self.rules_path()).unwrap_or_default()
    }

    pub fn dossiers(&self) -> Result<Vec<Dossier>> {
        let mut out = Vec::new();
        let dir = self.repos_dir();
        if !dir.is_dir() {
            return Ok(out);
        }
        for entry in fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.join("repo.json").is_file() {
                out.push(Dossier::load(&path)?);
            }
        }
        out.sort_by(|a, b| a.meta.identity.cmp(&b.meta.identity));
        Ok(out)
    }

    pub fn find(&self, identity: &str) -> Result<Option<Dossier>> {
        let dir = self.repos_dir().join(slug(identity));
        if dir.join("repo.json").is_file() {
            Ok(Some(Dossier::load(&dir)?))
        } else {
            Ok(None)
        }
    }

    pub fn create(&self, identity: &str) -> Result<Dossier> {
        let dir = self.repos_dir().join(slug(identity));
        let d = Dossier {
            dir,
            meta: RepoMeta {
                identity: identity.to_string(),
                paths: Vec::new(),
                created: date::today(),
            },
        };
        fs::create_dir_all(d.tasks_dir())?;
        d.save_meta()?;
        Ok(d)
    }

    pub fn find_or_create(&self, identity: &str) -> Result<(Dossier, bool)> {
        match self.find(identity)? {
            Some(d) => Ok((d, false)),
            None => Ok((self.create(identity)?, true)),
        }
    }

    /// A dossier from `spec` (a folder, an identity, or the last part of one), or from `cwd`.
    pub fn resolve_repo(&self, spec: Option<&str>, cwd: &Path) -> Result<Dossier> {
        self.require()?;
        let spec = spec.map(str::trim).filter(|s| !s.is_empty());
        let folder = match spec {
            None => Some(cwd.to_path_buf()),
            Some(s) if Path::new(s).is_dir() => Some(PathBuf::from(s)),
            Some(_) => None,
        };
        if let Some(folder) = folder {
            let root = git::repo_root(&folder).ok_or_else(|| {
                anyhow!(
                    "{} is not inside a Git repository; pass a repository ({})",
                    folder.display(),
                    self.known()
                )
            })?;
            let id = git::identity(&root);
            return self.find(&id)?.ok_or_else(|| {
                anyhow!(
                    "{id} is not added yet; run `sb add` inside it, or pass a repository ({})",
                    self.known()
                )
            });
        }
        let s = spec.unwrap_or_default().to_lowercase();
        if let Some(d) = self.find(&s)? {
            return Ok(d);
        }
        let mut hits: Vec<Dossier> = self
            .dossiers()?
            .into_iter()
            .filter(|d| d.meta.identity.rsplit('/').next() == Some(s.as_str()))
            .collect();
        match hits.len() {
            1 => Ok(hits.remove(0)),
            0 => bail!("unknown repository '{s}'; known: {}", self.known()),
            _ => bail!(
                "'{s}' matches several repositories: {}",
                hits.iter()
                    .map(|d| d.meta.identity.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }

    fn known(&self) -> String {
        let ids: Vec<String> = self
            .dossiers()
            .unwrap_or_default()
            .into_iter()
            .map(|d| d.meta.identity)
            .collect();
        if ids.is_empty() {
            "none yet".into()
        } else {
            ids.join(", ")
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RepoMeta {
    pub identity: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub created: String,
}

pub struct Dossier {
    pub dir: PathBuf,
    pub meta: RepoMeta,
}

impl Dossier {
    pub fn load(dir: &Path) -> Result<Dossier> {
        let file = dir.join("repo.json");
        let text =
            fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
        let meta =
            serde_json::from_str(&text).with_context(|| format!("parsing {}", file.display()))?;
        Ok(Dossier {
            dir: dir.to_path_buf(),
            meta,
        })
    }

    pub fn save_meta(&self) -> Result<()> {
        write_atomic(
            &self.dir.join("repo.json"),
            &(serde_json::to_string_pretty(&self.meta)? + "\n"),
        )
    }

    /// Remembers a checkout folder; true when it was new.
    pub fn add_path(&mut self, path: &str) -> bool {
        let norm = |p: &str| p.replace('\\', "/").trim_end_matches('/').to_lowercase();
        if self.meta.paths.iter().any(|p| norm(p) == norm(path)) {
            return false;
        }
        self.meta.paths.push(path.to_string());
        true
    }

    pub fn remove_path(&mut self, path: &str) {
        let norm = |p: &str| p.replace('\\', "/").trim_end_matches('/').to_lowercase();
        self.meta.paths.retain(|p| norm(p) != norm(path));
    }

    pub fn tasks_dir(&self) -> PathBuf {
        self.dir.join("tasks")
    }

    pub fn context(&self) -> String {
        fs::read_to_string(self.dir.join("context.md")).unwrap_or_default()
    }

    pub fn set_context(&self, text: &str) -> Result<()> {
        let text = text.replace("\r\n", "\n");
        write_atomic(
            &self.dir.join("context.md"),
            &format!("{}\n", text.trim_end()),
        )
    }

    /// Decision lines, oldest first.
    pub fn decisions(&self) -> Vec<String> {
        fs::read_to_string(self.dir.join("decisions.md"))
            .unwrap_or_default()
            .lines()
            .filter(|l| l.starts_with("- "))
            .map(str::to_string)
            .collect()
    }

    pub fn add_decision(&self, text: &str) -> Result<String> {
        let text = crate::task::one_line(text);
        if text.is_empty() {
            bail!("the decision text is empty");
        }
        let file = self.dir.join("decisions.md");
        let mut all = fs::read_to_string(&file).unwrap_or_else(|_| "# Decisions\n\n".into());
        if !all.ends_with('\n') {
            all.push('\n');
        }
        let line = format!("- {}: {}", date::today(), text);
        all.push_str(&line);
        all.push('\n');
        write_atomic(&file, &all)?;
        Ok(line)
    }

    /// Every task with its file, sorted by id.
    pub fn task_files(&self) -> Result<Vec<(PathBuf, Task)>> {
        let mut out = Vec::new();
        let dir = self.tasks_dir();
        if !dir.is_dir() {
            return Ok(out);
        }
        for entry in fs::read_dir(&dir)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let text = fs::read_to_string(&path)?;
            let task =
                Task::parse(&text).with_context(|| format!("task file {}", path.display()))?;
            out.push((path, task));
        }
        out.sort_by_key(|(_, t)| t.id);
        Ok(out)
    }

    pub fn tasks(&self) -> Result<Vec<Task>> {
        Ok(self.task_files()?.into_iter().map(|(_, t)| t).collect())
    }

    pub fn task(&self, id: u32) -> Result<Task> {
        self.tasks()?
            .into_iter()
            .find(|t| t.id == id)
            .ok_or_else(|| anyhow!("no task #{id} in {}", self.meta.identity))
    }

    pub fn next_id(&self) -> Result<u32> {
        Ok(self.tasks()?.iter().map(|t| t.id).max().unwrap_or(0) + 1)
    }

    /// Writes a task to its existing file, or to a new `0012-title.md`.
    pub fn save_task(&self, task: &Task) -> Result<PathBuf> {
        let existing = self
            .task_files()?
            .into_iter()
            .find(|(_, t)| t.id == task.id)
            .map(|(p, _)| p);
        let path = existing.unwrap_or_else(|| self.tasks_dir().join(file_name(task)));
        write_atomic(&path, &task.to_markdown())?;
        Ok(path)
    }

    pub fn add_task(
        &self,
        title: &str,
        body: &str,
        priority: Option<u8>,
        needs_user: bool,
    ) -> Result<Task> {
        if title.trim().is_empty() {
            bail!("the task title is empty");
        }
        let mut t = Task::new(self.next_id()?, title, &date::today());
        t.body = body.trim().to_string();
        t.priority = priority;
        t.needs_user = needs_user;
        self.save_task(&t)?;
        Ok(t)
    }

    pub fn set_status(&self, id: u32, status: Status) -> Result<Task> {
        let mut t = self.task(id)?;
        t.status = status;
        t.updated = date::today();
        self.save_task(&t)?;
        Ok(t)
    }
}

fn file_name(task: &Task) -> String {
    let mut slug = String::new();
    for c in task.title.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
        } else if !slug.ends_with('-') && !slug.is_empty() {
            slug.push('-');
        }
        if slug.len() >= 48 {
            break;
        }
    }
    let slug = slug.trim_end_matches('-');
    if slug.is_empty() {
        format!("{:04}.md", task.id)
    } else {
        format!("{:04}-{slug}.md", task.id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(slug("github.com/owner/name"), "github.com--owner--name");
        assert_eq!(slug("local/my repo"), "local--my_repo");
        let t = Task::new(12, "Fix: the *login* redirect (Chrome)!", "2026-11-25");
        assert_eq!(file_name(&t), "0012-fix-the-login-redirect-chrome.md");
        assert_eq!(file_name(&Task::new(3, "###", "x")), "0003.md");
    }
}
