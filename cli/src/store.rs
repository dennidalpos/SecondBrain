//! The SecondBrain home (the user data folder `sb`, or `SB_HOME`) and one dossier per repository:
//!
//! ```text
//! <data folder>/
//!   rules.md                      shared rules copied into every linked AGENTS.md
//!   repos/<repository folder>/
//!     repo.json                   identity (synced)
//!     paths.json                  checkout folders on this machine (never synced)
//!     context.md                  current state, replaced as it changes
//!     decisions.md                one dated line per durable decision
//!     tasks/0012-fix-login.md     one file per task
//!     tasks-archive/              done tasks moved by `sb task archive`
//!     decisions-archive.md        old decisions moved by `sb task archive`
//! ```

use crate::date;
use crate::git;
use crate::task::{Status, Task, one_line};
use anyhow::{Context as _, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

const RULES_TEMPLATE: &str = "# Shared rules\n\n<!-- Rules written here are copied into the SecondBrain block of every linked repository's AGENTS.md when you run `sb rules sync`. Keep them short. HTML comments like this one are not copied. -->\n";
const ATTRIBUTES_TEMPLATE: &str = "* text eol=lf\n";

pub(crate) fn unique_token() -> String {
    use std::hash::{BuildHasher, RandomState};
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let key = (std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed));
    let high = RandomState::new().hash_one(key);
    let low = RandomState::new().hash_one((high, key));
    format!("{high:016x}{low:016x}")
}

fn legacy_task_key(path: &Path) -> String {
    use std::fmt::Write as _;
    let mut key = String::from("legacy-");
    for byte in path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .bytes()
    {
        write!(key, "{byte:02x}").expect("writing to a String");
    }
    key
}

pub(crate) fn read_optional(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

/// Writes through a temporary file and a rename, so a crash never leaves half a file.
pub fn write_atomic(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(format!(".{}.tmp", unique_token()));
    let tmp = PathBuf::from(tmp);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .with_context(|| format!("creating {}", tmp.display()))?;
    let written = file.write_all(content.as_bytes());
    drop(file);
    if let Err(error) = written {
        let _ = fs::remove_file(&tmp);
        return Err(error).with_context(|| format!("writing {}", tmp.display()));
    }
    // A reader holding the target open (or a scanner) can make the rename fail for a moment on
    // Windows; retry briefly before giving up.
    let mut last = None;
    for _ in 0..40 {
        match fs::rename(&tmp, path) {
            Ok(()) => return Ok(()),
            Err(e) => {
                last = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(15));
            }
        }
    }
    let _ = fs::remove_file(&tmp);
    Err(last.unwrap()).with_context(|| format!("replacing {}", path.display()))
}

pub const PATHS_FILE: &str = "paths.json";

/// The original directory format is retained for reading existing dossiers.
pub fn legacy_slug(identity: &str) -> String {
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

/// A reversible directory name with a prefix unavailable in the legacy format.
pub fn slug(identity: &str) -> String {
    use std::fmt::Write as _;

    let mut name = String::from("~");
    for byte in identity.bytes() {
        match byte {
            b'/' => name.push('!'),
            b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-' => name.push(char::from(byte)),
            b'.' => name.push('.'),
            _ => write!(name, "%{byte:02x}").expect("writing to a String"),
        }
    }
    // Windows removes trailing dots from ordinary directory names.
    name.push('~');
    name
}

fn user_home() -> Result<PathBuf> {
    let vars: &[&str] = if cfg!(windows) {
        &["USERPROFILE", "HOME"]
    } else {
        &["HOME"]
    };
    vars.iter()
        .find_map(|v| env::var_os(v).filter(|x| !x.is_empty()))
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("cannot find your home folder; set SB_HOME"))
}

/// The default data folder `sb` of the user: `%LOCALAPPDATA%\sb` on Windows,
/// `~/Library/Application Support/sb` on macOS, `$XDG_DATA_HOME/sb` (or `~/.local/share/sb`) elsewhere.
fn data_dir(user: &Path) -> PathBuf {
    if cfg!(windows) {
        env::var_os("LOCALAPPDATA")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| user.join("AppData").join("Local"))
            .join("sb")
    } else if cfg!(target_os = "macos") {
        user.join("Library").join("Application Support").join("sb")
    } else {
        env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| user.join(".local").join("share"))
            .join("sb")
    }
}

/// Moves a SecondBrain 5 alpha folder (`~/.secondbrain`) to the data folder and leaves a note behind.
fn migrate_home(old: &Path, new: &Path) -> Result<()> {
    if let Some(parent) = new.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::rename(old, new).with_context(|| {
        format!(
            "moving {} to {}; move it by hand or set SB_HOME to the old folder",
            old.display(),
            new.display()
        )
    })?;
    fs::create_dir_all(old)?;
    write_atomic(
        &old.join("MOVED.txt"),
        &format!(
            "SecondBrain data now lives in {}. This folder can be deleted.\n",
            new.display()
        ),
    )?;
    Ok(())
}

pub struct Home {
    pub root: PathBuf,
}

impl Home {
    /// `--home`, then `SB_HOME`, then the user data folder `sb` (see `data_dir`).
    pub fn resolve(explicit: Option<&Path>) -> Result<Home> {
        Self::resolve_with_migration(explicit, true)
    }

    /// Find the data folder for the status screen without moving a legacy folder.
    pub fn for_start(explicit: Option<&Path>) -> Result<Home> {
        Self::resolve_with_migration(explicit, false)
    }

    fn resolve_with_migration(explicit: Option<&Path>, migrate: bool) -> Result<Home> {
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
        let user = user_home()?;
        let root = data_dir(&user);
        let old = user.join(".secondbrain");
        if !root.exists() && old.join("repos").is_dir() {
            if !migrate {
                return Ok(Home { root: old });
            }
            migrate_home(&old, &root)?;
        }
        Ok(Home { root })
    }

    pub fn repos_dir(&self) -> PathBuf {
        self.root.join("repos")
    }

    pub fn rules_path(&self) -> PathBuf {
        self.root.join("rules.md")
    }

    pub fn skills_dir(&self) -> PathBuf {
        self.root.join("skills")
    }

    /// Replaces the general rules (`rules.md`).
    pub fn set_rules(&self, text: &str) -> Result<()> {
        let text = text.replace("\r\n", "\n");
        write_atomic(&self.rules_path(), &format!("{}\n", text.trim_end()))
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

    pub(crate) fn can_adopt_remote(&self) -> Result<bool> {
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            let path = entry.path();
            match entry.file_name().to_str() {
                Some(".git") => continue,
                Some("repos")
                    if kind.is_dir() && fs::read_dir(&path)?.next().transpose()?.is_none() =>
                {
                    continue;
                }
                Some("index.db" | "index.db-wal" | "index.db-shm") if kind.is_file() => continue,
                Some("rules.md")
                    if kind.is_file()
                        && fs::read_to_string(&path)?.replace("\r\n", "\n") == RULES_TEMPLATE =>
                {
                    continue;
                }
                Some(".gitattributes")
                    if kind.is_file()
                        && fs::read_to_string(&path)?.replace("\r\n", "\n")
                            == ATTRIBUTES_TEMPLATE =>
                {
                    continue;
                }
                Some(".gitignore")
                    if kind.is_file()
                        && fs::read_to_string(&path)?
                            .lines()
                            .all(|line| crate::sync::IGNORE_LINES.contains(&line)) =>
                {
                    continue;
                }
                _ => return Ok(false),
            }
        }
        Ok(true)
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
            write_atomic(&ignore, &(crate::sync::IGNORE_LINES.join("\n") + "\n"))?;
        }
        let attrs = self.root.join(".gitattributes");
        if !attrs.exists() {
            write_atomic(&attrs, ATTRIBUTES_TEMPLATE)?;
            done.push("created .gitattributes (keeps LF with core.autocrlf=true)".into());
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
        let modern = self.repos_dir().join(slug(identity));
        if modern.join("repo.json").is_file() {
            let dossier = Dossier::load(&modern)?;
            if dossier.meta.identity != identity {
                bail!(
                    "dossier at {} belongs to a different repository",
                    modern.display()
                );
            }
            return Ok(Some(dossier));
        }
        let legacy = self.repos_dir().join(legacy_slug(identity));
        if legacy.join("repo.json").is_file() {
            let dossier = Dossier::load(&legacy)?;
            return Ok((dossier.meta.identity == identity).then_some(dossier));
        }
        Ok(None)
    }

    pub fn create(&self, identity: &str) -> Result<Dossier> {
        let dir = self.repos_dir().join(slug(identity));
        let d = Dossier {
            dir,
            meta: RepoMeta {
                identity: identity.to_string(),
                paths: Vec::new(),
                created: date::today(),
                root: None,
            },
        };
        fs::create_dir_all(d.tasks_dir())?;
        d.save_meta()?;
        Ok(d)
    }

    pub fn find_or_create(&self, identity: &str) -> Result<(Dossier, bool)> {
        if let Some(dossier) = self.find(identity)? {
            return Ok((dossier, false));
        }
        let tasks = self.repos_dir().join(slug(identity)).join("tasks");
        with_dossier_lock(&tasks, || match self.find(identity)? {
            Some(dossier) => Ok((dossier, false)),
            None => Ok((self.create(identity)?, true)),
        })
    }

    pub(crate) fn find_checkout(&self, identity: &str, root: &Path) -> Result<Option<Dossier>> {
        if let Some(dossier) = self.find(identity)? {
            return Ok(Some(dossier));
        }
        if let Some(legacy) = git::legacy_local_identity(identity)
            && let Some(dossier) = self
                .find(legacy)?
                .filter(|dossier| dossier.matches_checkout(identity, root))
        {
            return Ok(Some(dossier));
        }
        self.find_by_path(root)
    }

    /// A local dossier (no GitHub remote) that records this folder: how a moved or renamed
    /// checkout keeps its dossier after `sb relink`, since its identity follows the folder.
    pub(crate) fn find_by_path(&self, root: &Path) -> Result<Option<Dossier>> {
        Ok(self.dossiers()?.into_iter().find(|d| {
            d.meta.identity.starts_with("local/")
                && d.has_path(&root.to_string_lossy())
                && d.same_history(root)
        }))
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
            return self.find_checkout(&id, &root)?.ok_or_else(|| {
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
            .filter(|d| {
                git::legacy_local_identity(&d.meta.identity)
                    .unwrap_or(&d.meta.identity)
                    .rsplit('/')
                    .next()
                    == Some(s.as_str())
            })
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
    /// Checkout folders on this machine. Kept in `paths.json` (never synced); read from
    /// `repo.json` only for dossiers written by an older build.
    #[serde(default, skip_serializing)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub created: String,
    /// Root commit id of the checkout recorded by `sb relink`, so a folder that was deleted
    /// and recreated as another repository does not attach to this dossier by path alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
}

pub struct Dossier {
    pub dir: PathBuf,
    pub meta: RepoMeta,
}

impl Dossier {
    /// False only when both the dossier and the folder have a root commit and they differ;
    /// repositories without commits fall back to matching by path.
    pub(crate) fn same_history(&self, root: &Path) -> bool {
        match (&self.meta.root, git::root_commit(root)) {
            (Some(recorded), Some(actual)) => *recorded == actual,
            _ => true,
        }
    }

    pub(crate) fn matches_checkout(&self, identity: &str, root: &Path) -> bool {
        self.meta.identity == identity
            // A relinked local repository: both have no GitHub remote and the folder is recorded.
            || (self.meta.identity.starts_with("local/")
                && identity.starts_with("local/")
                && self.has_path(&root.to_string_lossy())
                && self.same_history(root))
            || (git::legacy_local_identity(identity) == Some(&self.meta.identity)
                && self.meta.paths.first().is_some_and(|path| {
                    git::local_path_key(Path::new(path)) == git::local_path_key(root)
                }))
    }
    pub fn load(dir: &Path) -> Result<Dossier> {
        let file = dir.join("repo.json");
        let text =
            fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
        let mut meta: RepoMeta =
            serde_json::from_str(&text).with_context(|| format!("parsing {}", file.display()))?;
        if let Some(local) = read_optional(&dir.join(PATHS_FILE))? {
            let local: Vec<String> = serde_json::from_str(&local)
                .with_context(|| format!("parsing {}", dir.join(PATHS_FILE).display()))?;
            for p in local {
                if !meta.paths.contains(&p) {
                    meta.paths.push(p);
                }
            }
        }
        Ok(Dossier {
            dir: dir.to_path_buf(),
            meta,
        })
    }

    pub fn save_meta(&self) -> Result<()> {
        write_atomic(
            &self.dir.join("repo.json"),
            &(serde_json::to_string_pretty(&self.meta)? + "\n"),
        )?;
        write_atomic(
            &self.dir.join(PATHS_FILE),
            &(serde_json::to_string_pretty(&self.meta.paths)? + "\n"),
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

    pub fn has_path(&self, path: &str) -> bool {
        let norm = |p: &str| p.replace('\\', "/").trim_end_matches('/').to_lowercase();
        self.meta.paths.iter().any(|p| norm(p) == norm(path))
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

    /// The rules of this repository only (`rules.md` in its dossier).
    pub fn rules(&self) -> String {
        fs::read_to_string(self.dir.join("rules.md")).unwrap_or_default()
    }

    pub fn set_rules(&self, text: &str) -> Result<()> {
        let text = text.replace("\r\n", "\n");
        write_atomic(
            &self.dir.join("rules.md"),
            &format!("{}\n", text.trim_end()),
        )
    }

    pub fn set_context(&self, text: &str) -> Result<()> {
        self.with_lock(|| self.write_context(text))
    }

    pub fn set_initial_context(&self, text: &str) -> Result<()> {
        if text.trim().is_empty() {
            bail!("initial context must contain repository findings");
        }
        self.with_lock(|| {
            let current = read_optional(&self.dir.join("context.md"))?.unwrap_or_default();
            if !current.trim().is_empty() {
                bail!("this dossier already has context; read it before updating it");
            }
            self.write_context(text)
        })
    }

    fn write_context(&self, text: &str) -> Result<()> {
        let text = text.replace("\r\n", "\n");
        write_atomic(
            &self.dir.join("context.md"),
            &format!("{}\n", text.trim_end()),
        )
    }

    /// Decision lines, oldest first.
    pub fn decisions(&self) -> Result<Vec<String>> {
        Ok(read_optional(&self.dir.join("decisions.md"))?
            .unwrap_or_default()
            .lines()
            .filter(|l| l.starts_with("- "))
            .map(str::to_string)
            .collect())
    }

    pub fn add_decision(&self, text: &str) -> Result<String> {
        let text = crate::task::one_line(text);
        if text.is_empty() {
            bail!("the decision text is empty");
        }
        self.with_lock(|| {
            let file = self.dir.join("decisions.md");
            let mut all = read_optional(&file)?.unwrap_or_else(|| "# Decisions\n\n".into());
            if !all.ends_with('\n') {
                all.push('\n');
            }
            let line = format!("- {}: {}", date::today(), text);
            all.push_str(&line);
            all.push('\n');
            write_atomic(&file, &all)?;
            Ok(line)
        })
    }

    pub fn archive_dir(&self) -> PathBuf {
        self.dir.join("tasks-archive")
    }

    /// Decision lines moved out by `sb task archive`, oldest first.
    pub fn archived_decisions(&self) -> Result<Vec<String>> {
        Ok(read_optional(&self.dir.join("decisions-archive.md"))?
            .unwrap_or_default()
            .lines()
            .filter(|l| l.starts_with("- "))
            .map(str::to_string)
            .collect())
    }

    /// Done tasks moved out by `sb task archive`, sorted by id.
    pub fn archived_tasks(&self) -> Result<Vec<Task>> {
        let mut out = Vec::new();
        let dir = self.archive_dir();
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(out),
            Err(error) => return Err(error).with_context(|| format!("reading {}", dir.display())),
        };
        for entry in entries {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let text = fs::read_to_string(&path)?;
            let mut task =
                Task::parse(&text).with_context(|| format!("task file {}", path.display()))?;
            task.key.get_or_insert_with(|| legacy_task_key(&path));
            out.push(task);
        }
        out.sort_by_key(|t| t.id);
        Ok(out)
    }

    /// Moves done tasks and decisions last touched more than `days` days ago into
    /// `tasks-archive/` and `decisions-archive.md`. A done task a remaining task still depends
    /// on stays. Returns (tasks moved, decisions moved, tasks kept for a dependency).
    pub fn archive_old(&self, days: u64) -> Result<(Vec<Task>, usize, usize)> {
        let today = (date::now_secs() / 86_400) as i64;
        let cutoff = date::from_days(today.saturating_sub(i64::try_from(days).unwrap_or(i64::MAX)));
        self.with_lock(|| {
            let files = self.task_files()?;
            let mut moving: Vec<bool> = files
                .iter()
                .map(|(_, t)| !t.is_open() && t.updated.as_str() < cutoff.as_str())
                .collect();
            let candidates = moving.iter().filter(|m| **m).count();
            loop {
                let needed: Vec<usize> = (0..files.len())
                    .filter(|&i| {
                        let t = &files[i].1;
                        moving[i]
                            && files.iter().enumerate().any(|(j, (_, other))| {
                                !moving[j]
                                    && (other.blocked_by.contains(&t.id)
                                        || t.key
                                            .as_ref()
                                            .is_some_and(|k| other.blocker_keys.contains(k)))
                            })
                    })
                    .collect();
                if needed.is_empty() {
                    break;
                }
                for i in needed {
                    moving[i] = false;
                }
            }
            let kept = candidates - moving.iter().filter(|m| **m).count();

            let archive = self.archive_dir();
            let mut moved = Vec::new();
            for (flag, (path, task)) in moving.iter().zip(files) {
                if !*flag {
                    continue;
                }
                let name = path
                    .file_name()
                    .ok_or_else(|| anyhow!("task file has no name: {}", path.display()))?;
                let dest = archive.join(name);
                if dest.exists() {
                    bail!(
                        "{} already exists; resolve it before archiving",
                        dest.display()
                    );
                }
                fs::create_dir_all(&archive)?;
                fs::rename(&path, &dest)
                    .with_context(|| format!("moving {} to the archive", path.display()))?;
                moved.push(task);
            }

            let decisions = self.archive_decisions(&cutoff)?;
            Ok((moved, decisions, kept))
        })
    }

    /// Moves decision lines dated before `cutoff` to `decisions-archive.md` and leaves one
    /// pointer line in `decisions.md`. The archive is written first, so a crash duplicates
    /// lines instead of losing them.
    fn archive_decisions(&self, cutoff: &str) -> Result<usize> {
        const POINTER: &str = "Archived decisions: ";
        let file = self.dir.join("decisions.md");
        let text = read_optional(&file)?.unwrap_or_default();
        let (mut head, mut keep, mut old) = (Vec::new(), Vec::new(), Vec::new());
        for line in text.lines() {
            if line.starts_with("- ") {
                match line.get(2..12) {
                    Some(day) if day < cutoff => old.push(line),
                    _ => keep.push(line),
                }
            } else if !line.starts_with(POINTER) {
                head.push(line);
            }
        }
        if old.is_empty() {
            return Ok(0);
        }
        let archive = self.dir.join("decisions-archive.md");
        let mut all = read_optional(&archive)?.unwrap_or_else(|| "# Decisions archive\n\n".into());
        if !all.ends_with('\n') {
            all.push('\n');
        }
        for line in &old {
            all.push_str(line);
            all.push('\n');
        }
        write_atomic(&archive, &all)?;
        let total = all.lines().filter(|l| l.starts_with("- ")).count();
        let newest = all
            .lines()
            .filter(|l| l.starts_with("- "))
            .filter_map(|l| l.get(2..12))
            .max()
            .unwrap_or(cutoff);
        let mut out = head.join("\n").trim_end().to_string();
        out.push_str(&format!(
            "\n\n{POINTER}{total} in decisions-archive.md (up to {newest}); `sb search` still finds them.\n"
        ));
        if !keep.is_empty() {
            out.push('\n');
            out.push_str(&keep.join("\n"));
            out.push('\n');
        }
        write_atomic(&file, &out)?;
        Ok(old.len())
    }

    /// Every task with its file, sorted by id.
    pub fn task_files(&self) -> Result<Vec<(PathBuf, Task)>> {
        let mut out = Vec::new();
        let dir = self.tasks_dir();
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(out),
            Err(error) => return Err(error).with_context(|| format!("reading {}", dir.display())),
        };
        for entry in entries {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let text = fs::read_to_string(&path)?;
            let mut task =
                Task::parse(&text).with_context(|| format!("task file {}", path.display()))?;
            task.key.get_or_insert_with(|| legacy_task_key(&path));
            out.push((path, task));
        }
        out.sort_by_key(|(_, t)| t.id);
        Ok(out)
    }

    pub fn tasks(&self) -> Result<Vec<Task>> {
        let mut tasks: Vec<_> = self
            .task_files()?
            .into_iter()
            .map(|(_, task)| task)
            .collect();
        let mut ids = std::collections::HashSet::new();
        for task in &tasks {
            if !ids.insert(task.id) {
                bail!(
                    "task #{} is ambiguous; review `sb doctor` before using its number",
                    task.id
                );
            }
        }
        let keys = task_keys(&tasks)?;
        for task in &mut tasks {
            if !task.blocker_keys.is_empty()
                && let Some(ids) = resolve_blocker_keys(task, &keys)
            {
                task.blocked_by = ids;
            }
        }
        Ok(tasks)
    }

    pub fn task(&self, id: u32) -> Result<Task> {
        self.tasks()?
            .into_iter()
            .find(|t| t.id == id)
            .ok_or_else(|| anyhow!("no task #{id} in {}", self.meta.identity))
    }

    pub fn next_id(&self) -> Result<u32> {
        let archived = self.archived_tasks()?;
        self.tasks()?
            .iter()
            .chain(&archived)
            .map(|t| t.id)
            .max()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or_else(|| anyhow!("task ids exhausted"))
    }

    /// Holds an OS lock across the whole read-modify-write. The OS also releases it on exit.
    pub fn with_lock<T>(&self, f: impl FnOnce() -> Result<T>) -> Result<T> {
        with_dossier_lock(&self.tasks_dir(), f)
    }

    /// Writes a task to its existing file, or to a new `0012-title.md`.
    pub fn save_task(&self, task: &Task) -> Result<PathBuf> {
        self.with_lock(|| self.save_task_locked(task))
    }

    pub(crate) fn save_task_locked(&self, task: &Task) -> Result<PathBuf> {
        let existing = self
            .task_files()?
            .into_iter()
            .find(|(_, t)| {
                task.key
                    .as_ref()
                    .map_or(t.id == task.id, |key| t.key.as_ref() == Some(key))
            })
            .map(|(p, _)| p);
        let path = existing.unwrap_or_else(|| self.tasks_dir().join(file_name(task)));
        write_atomic(&path, &task.to_markdown())?;
        Ok(path)
    }

    /// Reassigns duplicate display numbers without moving files or guessing which task an
    /// ambiguous legacy dependency referred to. Returns (old, new, title).
    pub fn renumber_duplicates(&self) -> Result<Vec<(u32, u32, String)>> {
        self.with_lock(|| {
            let mut files = self.task_files()?;
            files.sort_by(|(pa, a), (pb, b)| (a.id, &a.created, pa).cmp(&(b.id, &b.created, pb)));
            let mut next = files.iter().map(|(_, t)| t.id).max().unwrap_or(0);
            let mut seen = std::collections::HashSet::new();
            let mut duplicates = std::collections::HashSet::new();
            for (_, task) in &files {
                if !seen.insert(task.id) { duplicates.insert(task.id); }
            }
            if duplicates.is_empty() { return Ok(Vec::new()); }
            for (_, task) in &files {
                if task.blocker_keys.is_empty() && task.blocked_by.iter().any(|id| duplicates.contains(id)) {
                    bail!("task #{} has an ambiguous legacy blocker; resolve the dependency in its task file before renumbering", task.id);
                }
            }
            seen.clear();
            let mut moved = Vec::new();
            let mut changed = std::collections::HashSet::new();
            for (path, task) in &mut files {
                if seen.insert(task.id) {
                    continue;
                }
                let old = task.id;
                next = next.checked_add(1).ok_or_else(|| anyhow!("task ids exhausted"))?;
                task.id = next;
                task.updated = date::today();
                changed.insert(path.clone());
                moved.push((old, task.id, task.title.clone()));
            }
            let tasks: Vec<_> = files.iter().map(|(_, task)| task.clone()).collect();
            let keys = task_keys(&tasks)?;
            for (path, task) in &mut files {
                if !task.blocker_keys.is_empty() {
                    let ids = resolve_blocker_keys(task, &keys).ok_or_else(|| anyhow!("task #{} has a missing blocker key", task.id))?;
                    if task.blocked_by != ids {
                        task.blocked_by = ids;
                        changed.insert(path.clone());
                    }
                }
            }
            for (path, task) in files {
                if changed.contains(&path) { write_atomic(&path, &task.to_markdown())?; }
            }
            Ok(moved)
        })
    }

    pub fn add_task(
        &self,
        title: &str,
        body: &str,
        priority: Option<u8>,
        needs_user: bool,
    ) -> Result<Task> {
        self.add_task_with(title, |task| {
            task.body = body.trim().to_string();
            task.priority = priority;
            task.needs_user = needs_user;
            Ok(())
        })
    }

    pub fn add_task_with(
        &self,
        title: &str,
        configure: impl FnOnce(&mut Task) -> Result<()>,
    ) -> Result<Task> {
        if title.trim().is_empty() {
            bail!("the task title is empty");
        }
        self.with_lock(|| {
            let tasks = self.tasks()?;
            let id = tasks
                .iter()
                .map(|task| task.id)
                .max()
                .unwrap_or(0)
                .checked_add(1)
                .ok_or_else(|| anyhow!("task ids exhausted"))?;
            let mut task = Task::new(id, title, &date::today());
            task.key = Some(unique_token());
            configure(&mut task)?;
            validate_blockers(&tasks, id, &task.blocked_by)?;
            bind_blockers(&mut task, &tasks)?;
            self.save_task_locked(&task)?;
            Ok(task)
        })
    }

    pub fn update_task(
        &self,
        id: u32,
        update: impl FnOnce(&mut Task) -> Result<()>,
    ) -> Result<Task> {
        self.with_lock(|| {
            let tasks = self.tasks()?;
            let original = tasks
                .iter()
                .find(|task| task.id == id)
                .ok_or_else(|| anyhow!("no task #{id} in {}", self.meta.identity))?;
            let mut task = original.clone();
            update(&mut task)?;
            if task.blocked_by != original.blocked_by || task.blocker_keys != original.blocker_keys
            {
                validate_blockers(&tasks, id, &task.blocked_by)?;
                bind_blockers(&mut task, &tasks)?;
            }
            task.updated = date::today();
            self.save_task_locked(&task)?;
            Ok(task)
        })
    }

    /// Replaces the blockers of a task; every id must exist and the graph must stay acyclic.
    pub fn set_blocked_by(&self, id: u32, blockers: &[u32]) -> Result<Task> {
        self.update_task(id, |task| {
            task.blocked_by = blockers.to_vec();
            Ok(())
        })
    }

    /// Open `todo` tasks (or `doing` ones whose lease ran out) with resolved dependencies.
    pub fn ready_tasks(&self) -> Result<Vec<Task>> {
        let tasks = self.tasks()?;
        validate_graph(&tasks)?;
        let now = date::now_secs();
        let mut ready: Vec<Task> = tasks
            .iter()
            .filter(|t| is_ready(t, &tasks, now))
            .cloned()
            .collect();
        ready.sort_by_key(|t| (t.priority.unwrap_or(9), t.id));
        Ok(ready)
    }

    /// Takes a ready task for `by` until the lease runs out; the check and the write happen under
    /// the lock, so two claimers never get the same task.
    pub fn claim_task(&self, id: u32, by: &str, minutes: u64) -> Result<Task> {
        self.claim(id, None, by, minutes)
    }

    pub(crate) fn claim_selected_task(&self, task: &Task, by: &str, minutes: u64) -> Result<Task> {
        self.claim(task.id, task.key.as_deref(), by, minutes)
    }

    fn claim(&self, id: u32, key: Option<&str>, by: &str, minutes: u64) -> Result<Task> {
        if by.trim().is_empty() {
            bail!("say who claims the task (--by)");
        }
        self.with_lock(|| {
            let tasks = self.tasks()?;
            validate_graph(&tasks)?;
            let now = date::now_secs();
            let mut t = tasks
                .iter()
                .find(|task| key.map_or(task.id == id, |key| task.key.as_deref() == Some(key)))
                .cloned()
                .ok_or_else(|| anyhow!("no task #{id} in {}", self.meta.identity))?;
            if !is_ready(&t, &tasks, now) {
                let why = if t.is_claimed(now) {
                    format!("held by {}", t.claimed_by.as_deref().unwrap_or("someone"))
                } else if t.needs_user {
                    "waiting on a person".to_string()
                } else if t.status != Status::Todo && t.status != Status::Doing {
                    format!("{}", t.status)
                } else {
                    "waiting for its blockers".to_string()
                };
                bail!("task #{id} is not ready: {why}");
            }
            t.status = Status::Doing;
            t.claimed_by = Some(one_line(by));
            t.claimed_until = Some(now.saturating_add(minutes.max(1).saturating_mul(60)));
            t.updated = date::today();
            self.save_task_locked(&t)?;
            Ok(t)
        })
    }

    /// Gives a claimed task back: `todo` again, no holder.
    pub fn release_task(&self, id: u32) -> Result<Task> {
        self.release_task_by(id, None)
    }

    pub(crate) fn release_task_by(&self, id: u32, by: Option<&str>) -> Result<Task> {
        self.with_lock(|| {
            let mut t = self
                .tasks()?
                .into_iter()
                .find(|t| t.id == id)
                .ok_or_else(|| anyhow!("no task #{id} in {}", self.meta.identity))?;
            if let Some(by) = by {
                t.require_claim_by(by)?;
            }
            t.claimed_by = None;
            t.claimed_until = None;
            if t.status == Status::Doing {
                t.status = Status::Todo;
            }
            t.updated = date::today();
            self.save_task_locked(&t)?;
            Ok(t)
        })
    }

    pub(crate) fn finish_owned_claim<T>(
        &self,
        claim: &Task,
        finish: impl FnOnce(&mut Task) -> Result<T>,
    ) -> Result<T> {
        self.with_lock(|| {
            let mut task = self
                .tasks()?
                .into_iter()
                .find(|task| task.key == claim.key)
                .ok_or_else(|| anyhow!("claimed task #{} disappeared", claim.id))?;
            if task.status != Status::Doing
                || !task.is_claimed(date::now_secs())
                || task.claimed_by != claim.claimed_by
                || task.claimed_until != claim.claimed_until
            {
                bail!(
                    "task #{} is no longer owned by this run; its changes are left in the worktree",
                    task.id
                );
            }
            let result = finish(&mut task)?;
            task.claimed_by = None;
            task.claimed_until = None;
            task.updated = date::today();
            self.save_task_locked(&task)?;
            Ok(result)
        })
    }

    pub fn set_status(&self, id: u32, status: Status) -> Result<Task> {
        self.update_task(id, |task| {
            task.status = status;
            Ok(())
        })
    }
}

fn with_dossier_lock<T>(tasks_dir: &Path, f: impl FnOnce() -> Result<T>) -> Result<T> {
    use std::fs::TryLockError;
    use std::time::{Duration, Instant};

    fs::create_dir_all(tasks_dir)?;
    let lock = tasks_dir.join(".lock");
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&lock)
        .with_context(|| format!("opening dossier lock {}", lock.display()))?;
    let started = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return f(),
            Err(TryLockError::WouldBlock) if started.elapsed() < Duration::from_secs(10) => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(TryLockError::WouldBlock) => {
                bail!(
                    "another process holds the dossier lock ({})",
                    lock.display()
                );
            }
            Err(TryLockError::Error(error)) => {
                return Err(error).with_context(|| format!("locking {}", lock.display()));
            }
        }
    }
}

/// True when `t` can start now: free, not waiting on a person, every blocker done.
pub fn is_ready(t: &Task, all: &[Task], now: u64) -> bool {
    let startable = match t.status {
        Status::Todo => true,
        Status::Doing => t.claimed_until.is_some() && !t.is_claimed(now),
        _ => false,
    };
    startable
        && !t.needs_user
        && !t.is_claimed(now)
        && t.blocked_by.iter().all(|b| {
            all.iter()
                .find(|x| x.id == *b)
                .is_some_and(|x| !x.is_open())
        })
        && t.blocker_keys.iter().all(|key| {
            all.iter()
                .any(|task| task.key.as_ref() == Some(key) && !task.is_open())
        })
}

fn task_keys(tasks: &[Task]) -> Result<std::collections::HashMap<String, u32>> {
    let mut keys = std::collections::HashMap::new();
    for task in tasks {
        if let Some(key) = &task.key
            && keys.insert(key.clone(), task.id).is_some()
        {
            bail!(
                "tasks share a stable identity; resolve the duplicate task files before continuing"
            );
        }
    }
    Ok(keys)
}

fn resolve_blocker_keys(
    task: &Task,
    keys: &std::collections::HashMap<String, u32>,
) -> Option<Vec<u32>> {
    task.blocker_keys
        .iter()
        .map(|key| keys.get(key).copied())
        .collect()
}

fn bind_blockers(task: &mut Task, tasks: &[Task]) -> Result<()> {
    task.blocker_keys = task
        .blocked_by
        .iter()
        .map(|id| {
            tasks
                .iter()
                .find(|task| task.id == *id)
                .and_then(|task| task.key.clone())
                .ok_or_else(|| anyhow!("missing identity for blocker #{id}"))
        })
        .collect::<Result<_>>()?;
    Ok(())
}

pub(crate) fn validate_graph(tasks: &[Task]) -> Result<()> {
    let keys = task_keys(tasks)?;
    for task in tasks.iter().filter(|task| task.is_open()) {
        if !task.blocker_keys.is_empty() && resolve_blocker_keys(task, &keys).is_none() {
            bail!(
                "task #{} has a missing blocker key; correct its dependencies",
                task.id
            );
        }
        validate_blockers(tasks, task.id, &task.blocked_by)?;
    }
    Ok(())
}

/// The id at which giving `id` the blockers `blockers` would close a loop, if any.
fn validate_blockers(tasks: &[Task], id: u32, blockers: &[u32]) -> Result<()> {
    for blocker in blockers {
        if *blocker != id && !tasks.iter().any(|task| task.id == *blocker) {
            bail!("blocked-by: no task #{blocker}");
        }
    }
    if let Some(cycle) = would_cycle(tasks, id, blockers) {
        bail!("blocked-by would make a cycle through #{cycle}");
    }
    Ok(())
}

fn would_cycle(all: &[Task], id: u32, blockers: &[u32]) -> Option<u32> {
    let mut stack: Vec<u32> = blockers.to_vec();
    let mut seen = Vec::new();
    while let Some(n) = stack.pop() {
        if n == id {
            return Some(n);
        }
        if seen.contains(&n) {
            continue;
        }
        seen.push(n);
        if let Some(t) = all.iter().find(|t| t.id == n) {
            stack.extend(t.blocked_by.iter().copied());
        }
    }
    None
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
    let mut name = format!("{:04}", task.id);
    if !slug.is_empty() {
        name.push('-');
        name.push_str(slug);
    }
    if let Some(key) = &task.key {
        name.push('-');
        name.push_str(key);
    }
    name.push_str(".md");
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(slug("github.com/owner/name"), "~github.com!owner!name~");
        assert_ne!(slug("local/my repo"), slug("local/my_repo"));
        assert_ne!(slug("host/team--one/repo"), slug("host/team/one--repo"));
        assert_ne!(slug("local/a!b"), slug("local/a/b"));
        let t = Task::new(12, "Fix: the *login* redirect (Chrome)!", "2026-11-25");
        assert_eq!(file_name(&t), "0012-fix-the-login-redirect-chrome.md");
        assert_eq!(file_name(&Task::new(3, "###", "x")), "0003.md");
    }

    #[test]
    fn data_folder_is_named_sb_and_old_home_moves() {
        let user = std::env::temp_dir().join(format!("sb-test-data-{}", std::process::id()));
        assert!(data_dir(&user).ends_with("sb"));
        let (old, new) = (user.join(".secondbrain"), user.join("data").join("sb"));
        fs::create_dir_all(old.join("repos")).unwrap();
        fs::write(
            old.join("rules.md"),
            "r
",
        )
        .unwrap();
        migrate_home(&old, &new).unwrap();
        assert_eq!(
            fs::read_to_string(new.join("rules.md")).unwrap(),
            "r
"
        );
        assert!(old.join("MOVED.txt").is_file() && !old.join("repos").exists());
        fs::remove_dir_all(&user).unwrap();
    }
}
