//! `sb doctor [--fix]`: finds what drifted and puts it back in line.
//!
//! Checks the data folder, every dossier (identity, recorded checkout folders, tasks), the
//! SecondBrain block and pointer files in each linked checkout, and the MCP registrations.
//! Without `--fix` nothing is written. With it, only safe repairs are made; anything that needs a
//! decision (a repository that moved to another remote, a broken file) is reported.

use crate::block;
use crate::executable;
use crate::git;
use crate::mcp_install::{self, Dirs, Launch};
use crate::ops;
use crate::store::{Dossier, Home, legacy_slug, slug};
use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Repaired by this run.
    Fixed,
    /// `--fix` would repair it.
    Fixable,
    /// Needs a person.
    Manual,
}

#[derive(Clone, Debug)]
pub struct Finding {
    pub scope: String,
    pub text: String,
    pub state: State,
}

pub struct Options<'a> {
    pub fix: bool,
    /// What a registration should start; used to repair the MCP entries.
    pub launch: &'a Launch,
    pub dirs: &'a Dirs,
    /// Also ask `claude mcp get` about Claude Code (spawns a process).
    pub external: bool,
}

struct Ctx {
    fix: bool,
    out: Vec<Finding>,
}

impl Ctx {
    /// Records a repairable problem; `repair` runs only with `--fix`.
    fn repairable(&mut self, scope: &str, text: String, repair: impl FnOnce() -> Result<()>) {
        let state = if self.fix {
            match repair() {
                Ok(()) => State::Fixed,
                Err(e) => {
                    self.manual(scope, format!("{text} (repair failed: {e:#})"));
                    return;
                }
            }
        } else {
            State::Fixable
        };
        self.out.push(Finding {
            scope: scope.into(),
            text,
            state,
        });
    }

    fn manual(&mut self, scope: &str, text: String) {
        self.out.push(Finding {
            scope: scope.into(),
            text,
            state: State::Manual,
        });
    }
}

fn norm(p: &str) -> String {
    p.replace('\\', "/").trim_end_matches('/').to_lowercase()
}

pub fn run(home: &Home, opts: &Options) -> Result<Vec<Finding>> {
    let mut cx = Ctx {
        fix: opts.fix,
        out: Vec::new(),
    };
    if !check_home(home, opts.dirs, &mut cx) {
        return Ok(cx.out);
    }
    dossiers(home, &mut cx)?;
    search_index(home, &mut cx);
    source_databases(home, &mut cx);
    mcp(home, opts, None, &mut cx);
    Ok(cx.out)
}

pub(crate) struct StartupHealth {
    pub findings: Vec<Finding>,
    pub checkouts: usize,
    pub instruction_issues: usize,
    pub task_issues: usize,
    pub mcp_issues: usize,
    pub has_block: bool,
    pub agents: Vec<&'static mcp_install::Client>,
}

/// Check managed files in recorded checkouts and the task files of the current repository.
pub(crate) fn startup_health(
    home: &Home,
    dirs: &Dirs,
    launch: &Launch,
    checkout: Option<(&Path, &Dossier)>,
    executable: &executable::Status,
) -> StartupHealth {
    let opts = Options {
        fix: false,
        launch,
        dirs,
        external: false,
    };
    let mut cx = Ctx {
        fix: false,
        out: Vec::new(),
    };
    let mut health = StartupHealth {
        findings: Vec::new(),
        checkouts: 0,
        instruction_issues: 0,
        task_issues: 0,
        mcp_issues: 0,
        has_block: false,
        agents: Vec::new(),
    };
    if check_home(home, dirs, &mut cx) {
        startup_checkouts(
            home,
            checkout,
            executable.may_repair(),
            &mut health,
            &mut cx,
        );
        if let Some((_, dossier)) = checkout {
            let before = cx.out.len();
            tasks(dossier, &mut cx);
            health.task_issues = cx.out.len() - before;
        }
        let before = cx.out.len();
        health.agents = mcp(home, &opts, Some(executable), &mut cx);
        health.mcp_issues = cx.out.len() - before;
    }
    health.findings = cx.out;
    health
}

fn startup_checkouts(
    home: &Home,
    current: Option<(&Path, &Dossier)>,
    repair: bool,
    health: &mut StartupHealth,
    cx: &mut Ctx,
) {
    let rules = match fs::read_to_string(home.rules_path()) {
        Ok(rules) => rules,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => {
            cx.manual(
                "home",
                format!("cannot read shared rules ({error}); restore access and rerun `sb start`"),
            );
            return;
        }
    };
    let body = block::body(&rules);
    let entries = match fs::read_dir(home.repos_dir()) {
        Ok(entries) => entries,
        Err(error) => {
            cx.manual(
                "home",
                format!(
                    "cannot list recorded checkouts ({error}); restore access and rerun `sb start`"
                ),
            );
            return;
        }
    };
    let mut directories = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) if entry.path().join("repo.json").is_file() => directories.push(entry.path()),
            Ok(_) => {}
            Err(error) => cx.manual("home", format!("could not read a dossier directory entry ({error}); check access and rerun `sb start`")),
        }
    }
    directories.sort();
    let mut checked = HashSet::new();
    for dir in directories {
        let dossier = match Dossier::load(&dir) {
            Ok(dossier) => dossier,
            Err(error) => {
                cx.manual(
                    "dossier",
                    format!(
                        "cannot read {} ({error:#}); review it with `sb doctor`",
                        dir.display()
                    ),
                );
                continue;
            }
        };
        let identity = &dossier.meta.identity;
        for path in &dossier.meta.paths {
            let root = Path::new(path);
            let is_current = current.is_some_and(|(active, d)| {
                d.dir == dossier.dir
                    && checkout_key(&active.to_string_lossy()) == checkout_key(path)
            });
            if !is_current
                && !matches!(ops::checkout(root), Ok((actual, id)) if checkout_key(&actual) == checkout_key(path) && dossier.matches_checkout(&id, root))
            {
                cx.manual(identity, format!("{path} is unavailable or its Git identity changed; restore the checkout or review it with `sb doctor`"));
                continue;
            }
            if !checked.insert(checkout_key(path)) {
                continue;
            }
            health.checkouts += 1;
            let before = cx.out.len();
            let has_block = startup_files(root, &dossier, &body, &rules, repair, cx);
            if is_current {
                health.has_block = has_block;
                health.instruction_issues = cx.out[before..]
                    .iter()
                    .filter(|finding| finding.state != State::Fixed)
                    .count();
            }
        }
    }
}

fn startup_files(
    root: &Path,
    dossier: &Dossier,
    body: &str,
    rules: &str,
    repair: bool,
    cx: &mut Ctx,
) -> bool {
    let identity = &dossier.meta.identity;
    let mut local = Ctx {
        fix: false,
        out: Vec::new(),
    };
    let mut has_block = linked_files(identity, root, body, rules, &mut local);
    if repair
        && local
            .out
            .iter()
            .any(|finding| finding.state == State::Fixable)
    {
        match dossier.with_lock(|| {
            let mut repair = Ctx {
                fix: true,
                out: Vec::new(),
            };
            let has_block = linked_files(identity, root, body, rules, &mut repair);
            Ok((has_block, repair.out))
        }) {
            Ok((block, findings)) => {
                has_block = block;
                local.out = findings;
            }
            Err(error) => local.manual(
                identity,
                format!("could not repair agent files ({error:#}); retry `sb start`"),
            ),
        }
    }
    cx.out.extend(local.out);
    has_block
}

fn checkout_key(path: &str) -> String {
    if cfg!(windows) {
        norm(path)
    } else {
        path.trim_end_matches('/').to_string()
    }
}

pub(crate) fn recorded_checkout(dossier: &Dossier, root: &str) -> bool {
    let root = checkout_key(root);
    dossier
        .meta
        .paths
        .iter()
        .any(|path| checkout_key(path) == root)
}

fn check_home(home: &Home, dirs: &Dirs, cx: &mut Ctx) -> bool {
    let scope = "home";
    if !home.is_initialized() || !home.rules_path().exists() {
        let text = if home.is_initialized() {
            "rules.md is missing; restore it from a known-good copy or run `sb init` to recreate the template".to_string()
        } else {
            format!("{} is not set up", home.root.display())
        };
        cx.repairable(scope, text, || home.init().map(|_| ()));
    }
    if !home.is_initialized() {
        return false;
    }
    legacy_folder(home, dirs, cx);
    true
}

/// The pre-move folder next to the new one: two copies of the data.
fn legacy_folder(home: &Home, dirs: &Dirs, cx: &mut Ctx) {
    let old = dirs.home.join(".secondbrain");
    if norm(&old.display().to_string()) != norm(&home.root.display().to_string())
        && old.join("repos").is_dir()
    {
        cx.manual(
            "home",
            format!(
                "an older data folder still exists at {}: compare it with {} and merge what is missing by hand",
                old.display(),
                home.root.display()
            ),
        );
    }
}

fn dossiers(home: &Home, cx: &mut Ctx) -> Result<()> {
    let rules = home.rules();
    let body = block::body(&rules);
    let mut seen: HashMap<String, String> = HashMap::new();
    let mut entries: Vec<_> = fs::read_dir(home.repos_dir())?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    entries.sort();
    for dir in entries {
        let name = dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if !dir.join("repo.json").is_file() {
            cx.manual(&name, "no repo.json: not a dossier".into());
            continue;
        }
        let mut d = match Dossier::load(&dir) {
            Ok(d) => d,
            Err(e) => {
                cx.manual(&name, format!("repo.json cannot be read: {e:#}"));
                continue;
            }
        };
        let identity = d.meta.identity.clone();
        if slug(&identity) != name && legacy_slug(&identity) != name {
            cx.manual(
                &name,
                format!(
                    "the folder should be named {} for {identity}; rename it by hand",
                    slug(&identity)
                ),
            );
        }
        if let Some(other) = seen.insert(identity.to_lowercase(), name.clone()) {
            cx.manual(
                &name,
                format!("same identity as {other}: merge the two dossiers by hand"),
            );
        }
        for root in paths(&mut d, cx)? {
            linked_files(&identity, &root, &body, &rules, cx);
        }
        tasks(&d, cx);
        let size = crate::ops::tokens(&d.context());
        if size > crate::ops::CONTEXT_WARN_TOKENS {
            cx.manual(
                &identity,
                format!(
                    "context.md is about {size} tokens (over {}); shorten it with `sb context --set` or read it trimmed with `sb context --compact`",
                    crate::ops::CONTEXT_WARN_TOKENS
                ),
            );
        }
    }
    Ok(())
}

/// Drops recorded checkout folders that are gone, not repositories any more, or listed twice.
fn paths(d: &mut Dossier, cx: &mut Ctx) -> Result<Vec<std::path::PathBuf>> {
    let identity = d.meta.identity.clone();
    let mut keep: Vec<String> = Vec::new();
    let mut verified = Vec::new();
    let mut known = HashSet::new();
    let mut changed = false;
    for p in d.meta.paths.clone() {
        if !known.insert(checkout_key(&p)) {
            changed = true;
            cx.out.push(Finding {
                scope: identity.clone(),
                text: format!("{p} is recorded twice"),
                state: if cx.fix { State::Fixed } else { State::Fixable },
            });
            continue;
        }
        let path = Path::new(&p);
        if !path.is_dir() {
            changed = true;
            cx.out.push(Finding {
                scope: identity.clone(),
                text: if identity.starts_with("local/") {
                    format!(
                        "{p} no longer exists: if the folder moved, run `sb relink {identity}` inside it; otherwise forget this checkout"
                    )
                } else {
                    format!("{p} no longer exists: forget this checkout")
                },
                state: if cx.fix { State::Fixed } else { State::Fixable },
            });
            continue;
        }
        match git::repo_root(path) {
            None => {
                changed = true;
                cx.out.push(Finding {
                    scope: identity.clone(),
                    text: format!("{p} is not a Git repository any more: forget this checkout"),
                    state: if cx.fix { State::Fixed } else { State::Fixable },
                });
                continue;
            }
            Some(root) => {
                let actual = git::identity(&root);
                if checkout_key(&ops::native_path(&root)) != checkout_key(&p)
                    || !d.matches_checkout(&actual, &root)
                {
                    cx.manual(
                        &identity,
                        format!(
                            "{p} no longer matches the recorded checkout for {identity} (found {actual}); verify the Git root and remote before relinking"
                        ),
                    );
                } else {
                    verified.push(root);
                }
            }
        }
        keep.push(p);
    }
    if changed && cx.fix {
        d.meta.paths = keep;
        d.save_meta()?;
    }
    Ok(verified)
}

/// The block in AGENTS.md and the pointer file of a checkout that is linked.
fn linked_files(identity: &str, root: &Path, body: &str, rules: &str, cx: &mut Ctx) -> bool {
    let agents = root.join("AGENTS.md");
    let old = match ops::read_link_file(&agents) {
        Ok(Some(text)) => text,
        Ok(None) => return false,
        Err(error) => {
            cx.manual(
                identity,
                format!("cannot read {}: {error}", agents.display()),
            );
            return false;
        }
    };
    let begins = old.matches(block::BEGIN).count();
    let ends = old.matches(block::END).count();
    if (begins != 0 || ends != 0) && (begins != 1 || ends != 1 || !block::has_block(&old)) {
        cx.manual(
            identity,
            format!("{} has ambiguous SecondBrain markers; restore one complete managed block and rerun `sb start`", agents.display()),
        );
        return false;
    }
    if !block::has_block(&old) {
        return false;
    }
    let updated = block::upsert(&old, body);
    if updated != old {
        let text = format!("update the SecondBrain block in {}", agents.display());
        let agents = agents.clone();
        cx.repairable(identity, text, move || {
            anyhow::ensure!(
                ops::read_link_file(&agents)?.as_deref() == Some(&old),
                "{} changed during the check; retry `sb start`",
                agents.display()
            );
            crate::store::write_atomic(&agents, &updated)
        });
    }
    let claude = root.join("CLAUDE.md");
    match ops::read_link_file(&claude) {
        Ok(None) => {
            let text = format!("create {} with an import of AGENTS.md", claude.display());
            let root = root.to_path_buf();
            cx.repairable(identity, text, move || {
                ops::link_files(&root, rules, &["claude".to_string()]).map(|_| ())
            });
        }
        Ok(Some(t)) if !t.contains("@AGENTS.md") => cx.manual(
            identity,
            format!(
                "{} does not import AGENTS.md: add a line `@AGENTS.md`",
                claude.display()
            ),
        ),
        Ok(Some(_)) => {}
        Err(error) => cx.manual(identity, format!("check {} ({error:#})", claude.display())),
    }
    let gemini = root.join("GEMINI.md");
    if let Ok(text) = fs::read_to_string(&gemini)
        && !text.contains("@AGENTS.md")
    {
        cx.manual(
            identity,
            format!(
                "{} does not import AGENTS.md: add a line `@AGENTS.md`",
                gemini.display()
            ),
        );
    }
    true
}

fn tasks(d: &Dossier, cx: &mut Ctx) {
    let identity = d.meta.identity.clone();
    match d.task_files() {
        Err(e) => cx.manual(&identity, format!("a task file cannot be read ({e:#}); restore it from a known-good copy and rerun `sb start`")),
        Ok(files) => {
            let mut ids = HashSet::new();
            let mut keys = HashSet::new();
            let duplicates: Vec<_> = files.iter().filter(|(_, task)| !ids.insert(task.id)).map(|(_, task)| task.id).collect();
            if files.iter().any(|(_, task)| !keys.insert(task.key.as_deref())) {
                cx.manual(&identity, "multiple task files share the same task identity; compare the files and resolve the duplicate".into());
            } else if let Some((path, task)) = files.iter().find(|(_, task)| task.blocker_keys.is_empty() && task.blocked_by.iter().any(|id| duplicates.contains(id))) {
                cx.manual(&identity, format!("task #{} has an ambiguous legacy blocker in {}; resolve its dependency before running `sb doctor --fix`", task.id, path.display()));
            } else if !duplicates.is_empty() {
                cx.repairable(&identity, format!("{} duplicate task number(s); run `sb doctor --fix` to reassign the numbers", duplicates.len()), || d.renumber_duplicates().map(|_| ()));
            } else if let Err(error) = d.tasks().and_then(|tasks| crate::store::validate_graph(&tasks)) {
                cx.manual(&identity, format!("task dependencies need attention ({error:#}); review them with `sb task list`"));
            }
        }
    }
}

/// The search index is disposable: a damaged one is removed and rebuilt by the next search.
fn search_index(home: &Home, cx: &mut Ctx) {
    if let Err(e) = crate::index::check(home) {
        cx.repairable(
            "search index",
            format!("index.db does not answer ({e:#}); it will be rebuilt"),
            || crate::index::reset(home),
        );
    }
}

/// A source database holds the only copy of its extracts: a damaged one is reported, not removed.
fn source_databases(home: &Home, cx: &mut Ctx) {
    for d in home.dossiers().unwrap_or_default() {
        if let Err(e) = crate::kb::check(&d) {
            cx.manual(
                &d.meta.identity,
                format!(
                    "kb.db does not answer ({e:#}); restore it from a backup or an export pack, or move it away to start over"
                ),
            );
        }
    }
}

/// Registrations that start a binary or a data folder that is not there.
fn mcp(
    home: &Home,
    opts: &Options,
    executable: Option<&executable::Status>,
    cx: &mut Ctx,
) -> Vec<&'static mcp_install::Client> {
    let mut agents = Vec::new();
    for client in mcp_install::CLIENTS {
        let Some((command, sb_home)) = mcp_install::registered(client, opts.dirs, opts.external)
        else {
            continue;
        };
        agents.push(client);
        let scope = format!("mcp {}", client.id);
        let mut problems = Vec::new();
        let bare = !command.contains(['/', '\\']);
        if !bare && !Path::new(&command).is_file() {
            problems.push(format!("the command {command} does not exist"));
        }
        if executable.is_some_and(|status| status.older_registration(Path::new(&command))) {
            cx.manual(&scope, format!("{command} points to an older SecondBrain build; run `sb mcp install --client {}` using the newer executable and restart the client", client.id));
        }
        if let Some(h) = &sb_home {
            if !Path::new(h).join("repos").is_dir() {
                problems.push(format!("SB_HOME={h} is not a SecondBrain folder"));
            } else if norm(h) != norm(&home.root.display().to_string()) {
                cx.manual(
                    &scope,
                    format!(
                        "SB_HOME={h} differs from the folder in use ({}): the client reads other data",
                        home.root.display()
                    ),
                );
            }
        }
        if problems.is_empty() {
            continue;
        }
        let text = format!(
            "{}; run `sb mcp install --client {}` and restart the client",
            problems.join("; "),
            client.id
        );
        cx.repairable(&scope, text, || {
            mcp_install::install(client, opts.dirs, opts.launch).map(|_| ())
        });
    }
    agents
}

pub fn text(findings: &[Finding], fix: bool) -> String {
    if findings.is_empty() {
        return "No problems found.\n".into();
    }
    let mut s = String::new();
    for f in findings {
        let tag = match f.state {
            State::Fixed => "fixed",
            State::Fixable => "fixable",
            State::Manual => "manual",
        };
        s.push_str(&format!("[{tag}] {}: {}\n", f.scope, f.text));
    }
    let count = |st| findings.iter().filter(|f| f.state == st).count();
    let (fixed, fixable, manual) = (
        count(State::Fixed),
        count(State::Fixable),
        count(State::Manual),
    );
    if fix {
        s.push_str(&format!("{fixed} fixed, {manual} need you.\n"));
    } else {
        s.push_str(&format!(
            "{fixable} can be fixed with `sb doctor --fix`, {manual} need you.\n"
        ));
    }
    s
}

/// True when something is still wrong after the run.
pub fn unresolved(findings: &[Finding]) -> bool {
    findings.iter().any(|f| f.state != State::Fixed)
}
