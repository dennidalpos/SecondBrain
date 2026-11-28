//! `sb sync`: keeps the SecondBrain folder in a private Git remote and in step between machines.
//!
//! The data folder is already a Git repository. A sync scans what it is about to publish with the
//! rules of `sb check` (secrets and personal data), commits, rebases onto the remote and pushes.
//! A finding stops the sync before anything leaves the machine. Nothing is encrypted: the remote
//! must be private.

use crate::check::{self, Kind, Scope};
use crate::store::{Home, read_optional, write_atomic};
use anyhow::{Context as _, Result, anyhow, bail};
use std::fs;
use std::path::Path;
use std::process::Command;

/// Lines every data folder keeps out of Git: temporary files, the rebuildable search index,
/// the task lock and the local run logs (they hold prompts and agent output).
pub const IGNORE_LINES: &[&str] = &[
    "*.tmp",
    "index.db",
    "index.db-wal",
    "index.db-shm",
    ".lock",
    "runs/",
    "paths.json",
    "kb.db",
    "kb.db-wal",
    "kb.db-shm",
    "originals/",
    "backups/",
];

const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;

fn git_bytes(home: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("git")
        .arg("--no-replace-objects")
        .arg("-C")
        .arg(home)
        .args(args)
        .output()
        .context("running git")?;
    if !out.status.success() {
        bail!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

fn git(home: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&git_bytes(home, args)?)
        .trim()
        .to_string())
}

fn git_ok(home: &Path, args: &[&str]) -> bool {
    git(home, args).is_ok()
}

/// Adds the missing lines of `IGNORE_LINES` to the folder's `.gitignore`.
pub fn ensure_ignore(home: &Home) -> Result<()> {
    let path = home.root.join(".gitignore");
    let current = read_optional(&path)?.unwrap_or_default();
    let have: Vec<&str> = current.lines().map(str::trim).collect();
    let missing: Vec<&&str> = IGNORE_LINES.iter().filter(|l| !have.contains(*l)).collect();
    if missing.is_empty() {
        return Ok(());
    }
    let mut text = current.clone();
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    for l in missing {
        text.push_str(l);
        text.push('\n');
    }
    write_atomic(&path, &text)
}

/// Secrets and personal data in the files that would be published (tracked or new, not ignored).
pub fn scan(home: &Home) -> Result<Vec<check::Finding>> {
    let list = git_bytes(&home.root, &["ls-files", "-co", "--exclude-standard", "-z"])?;
    let list = String::from_utf8_lossy(&list);
    let scope = Scope::default();
    let skip = check::ignored(&home.root);
    let mut out = Vec::new();
    for rel in list.split('\0').filter(|p| !p.is_empty()) {
        let path = home.root.join(rel);
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue; // binary
        };
        for (i, line) in text.lines().enumerate() {
            for f in check::scan_line(rel, i + 1, line, "working", &scope) {
                if matches!(f.kind, Kind::Secret | Kind::Personal) && !skip.contains(&f.fingerprint)
                {
                    out.push(f);
                }
            }
        }
    }
    Ok(out)
}

fn scan_outgoing(home: &Home, head: &str, upstream: Option<&str>) -> Result<Vec<check::Finding>> {
    let range = upstream.map_or_else(|| head.to_string(), |base| format!("{base}..{head}"));
    let mut findings = Vec::new();
    check::scan_git_commits(&home.root, &[&range], &Scope::default(), &mut findings)?;
    let ignored = check::ignored(&home.root);
    findings.retain(|finding| !ignored.contains(&finding.fingerprint));
    Ok(findings)
}

fn findings_text(findings: &[check::Finding], committed: bool) -> String {
    let mut s = String::new();
    for f in findings {
        s.push_str(&format!(
            "{}:{}  {}  {}  [{}]\n",
            f.path, f.line, f.rule, f.excerpt, f.fingerprint
        ));
    }
    let help = if committed {
        "Nothing was pushed. Remove the text from the outgoing commits before retrying."
    } else {
        "Nothing was committed or pushed. Remove the text before retrying."
    };
    s.push_str(&format!(
        "\n{} finding(s). {help} For a reviewed false positive, add the fingerprint to .sbcheck-ignore or use `{}` on the offending line.\n",
        findings.len(),
        check::INLINE_IGNORE
    ));
    s
}

fn current_branch(home: &Path) -> Result<String> {
    git(home, &["symbolic-ref", "--short", "HEAD"])
        .map_err(|_| anyhow!("the data folder has no current branch"))
}

fn has_commits(home: &Path) -> bool {
    git_ok(home, &["rev-parse", "--verify", "-q", "HEAD"])
}

/// The branch to follow on `origin`: ours if it exists there, else the only one.
fn remote_branch(home: &Path, ours: &str) -> Result<Option<String>> {
    let heads = git(home, &["ls-remote", "--heads", "origin"])?;
    let names: Vec<String> = heads
        .lines()
        .filter_map(|l| l.split_whitespace().nth(1))
        .filter_map(|r| r.strip_prefix("refs/heads/"))
        .map(str::to_string)
        .collect();
    if names.is_empty() {
        return Ok(None);
    }
    if names.iter().any(|n| n == ours) {
        return Ok(Some(ours.to_string()));
    }
    if names.len() == 1 {
        return Ok(Some(names[0].clone()));
    }
    bail!(
        "origin has several branches ({}) and none is {ours}",
        names.join(", ")
    )
}

/// Supply a committer identity for sync operations that create or replay commits.
fn git_with_identity(home: &Path, command: &[&str]) -> Result<String> {
    let mut args: Vec<&str> = Vec::new();
    let name_set = git(home, &["config", "user.name"]).is_ok_and(|n| !n.is_empty());
    let email_set = git(home, &["config", "user.email"]).is_ok_and(|n| !n.is_empty());
    if !name_set {
        args.extend(["-c", "user.name=sb"]);
    }
    if !email_set {
        args.extend(["-c", "user.email=sb@localhost.invalid"]);
    }
    args.extend_from_slice(command);
    git(home, &args)
}

fn commit(home: &Path, message: &str) -> Result<()> {
    git_with_identity(home, &["commit", "-q", "-m", message]).map(|_| ())
}

pub fn run(home: &Home, remote: Option<&str>, no_push: bool) -> Result<String> {
    home.require()?;
    if !crate::git::available() {
        bail!("git is not installed");
    }
    if !home.root.join(".git").exists() {
        bail!(
            "{} is not a Git repository; run `git init` there first",
            home.root.display()
        );
    }
    let dir = home.root.as_path();
    let mut out = String::new();

    // Remote.
    let has_origin = git_ok(dir, &["remote", "get-url", "origin"]);
    match (has_origin, remote) {
        (false, Some(url)) => {
            git(dir, &["remote", "add", "origin", url])?;
            out.push_str(&format!(
                "Remote origin set to {url} (it must be private)\n"
            ));
        }
        (false, None) => bail!("no remote yet: run `sb sync --remote <private Git URL>`"),
        (true, Some(url)) => {
            let current = git(dir, &["remote", "get-url", "origin"])?;
            if current != url {
                bail!(
                    "origin is already {current}; change it with `git remote set-url origin <url>`"
                );
            }
        }
        (true, None) => {}
    }

    // Look at the remote first: a fresh machine adopts it instead of inventing a second history.
    git(dir, &["fetch", "-q", "origin"])?;
    let ours = current_branch(dir)?;
    let theirs = remote_branch(dir, &ours)?;
    if let Some(branch) = &theirs
        && !has_commits(dir)
    {
        if !home.can_adopt_remote()? || !git(dir, &["diff", "--cached", "--name-only"])?.is_empty()
        {
            bail!(
                "both this folder and origin hold data and share no history; sync from the machine that has the data first, or empty this folder"
            );
        }
        let upstream = format!("origin/{branch}");
        git(
            dir,
            &[
                "checkout",
                "-q",
                "-f",
                "--no-overwrite-ignore",
                "-B",
                &ours,
                &upstream,
            ],
        )?;
        out.push_str(&format!(
            "Adopted {upstream}
"
        ));
    }

    // Older dossiers kept this machine's checkout paths in repo.json: move them out first.
    for d in home.dossiers()? {
        d.save_meta()?;
    }
    // Keep local-only files out, then scan what would be published.
    ensure_ignore(home)?;
    let findings = scan(home)?;
    if !findings.is_empty() {
        return Err(crate::cli::Exit {
            code: 2,
            text: findings_text(&findings, false),
        }
        .into());
    }

    // Commit local changes.
    git(dir, &["add", "-A"])?;
    let changed = !git(dir, &["status", "--porcelain"])?.is_empty();
    if changed {
        commit(dir, &format!("sb sync {}", crate::date::stamp()))?;
        out.push_str(
            "Committed the local changes
",
        );
    }

    // Bring in the remote.
    let upstream = theirs
        .as_ref()
        .map(|branch| git(dir, &["rev-parse", &format!("origin/{branch}")]))
        .transpose()?;
    if let Some(upstream) = upstream.as_deref() {
        if !git_ok(dir, &["merge-base", "HEAD", upstream]) {
            bail!(
                "this folder and origin share no history; start from an empty folder or an empty remote"
            );
        }
        if let Err(error) = git_with_identity(dir, &["rebase", upstream]) {
            let _ = git(dir, &["rebase", "--abort"]);
            return Err(error).with_context(|| {
                format!(
                    "could not rebase local SecondBrain changes in {}",
                    dir.display()
                )
            });
        }
    }

    let mut renumbered = 0;
    for dossier in home.dossiers()? {
        renumbered += dossier.renumber_duplicates()?.len();
        crate::store::validate_graph(&dossier.tasks()?)?;
    }
    if renumbered > 0 {
        git(dir, &["add", "-A"])?;
        commit(dir, "Reconcile SecondBrain task numbers")?;
        out.push_str(&format!(
            "Reassigned {renumbered} duplicate task number(s)\n"
        ));
    }

    // Push.
    if no_push {
        out.push_str("Not pushed (--no-push)\n");
    } else if has_commits(dir) {
        let head = git(dir, &["rev-parse", "HEAD"])?;
        let fetch_url = git(dir, &["remote", "get-url", "origin"])?;
        let push_url = git(dir, &["remote", "get-url", "--push", "--all", "origin"])?;
        let scanned_base = if push_url == fetch_url {
            upstream.as_deref()
        } else {
            // The fetch remote cannot establish what a different push destination already holds.
            None
        };
        if scanned_base != Some(head.as_str()) {
            let findings = scan_outgoing(home, &head, scanned_base)?;
            if !findings.is_empty() {
                return Err(crate::cli::Exit {
                    code: 2,
                    text: findings_text(&findings, true),
                }
                .into());
            }
            let destination = format!("refs/heads/{}", theirs.as_deref().unwrap_or(&ours));
            let refspec = format!("{head}:{destination}");
            let mut args = vec!["push", "-q", "--no-follow-tags", "--recurse-submodules=no"];
            let lease;
            if let Some(base) = scanned_base {
                // A rewind at the destination could otherwise introduce previously scanned-out history.
                // Although the lease permits force, only allow a verified fast-forward from its base.
                git(dir, &["merge-base", "--is-ancestor", base, &head])?;
                lease = format!("--force-with-lease={destination}:{base}");
                args.push(&lease);
            }
            args.extend(["origin", &refspec]);
            git(dir, &args)?;
            let tracking = format!("origin/{}", theirs.as_deref().unwrap_or(&ours));
            if push_url == fetch_url && git_ok(dir, &["rev-parse", "--verify", &tracking]) {
                git(dir, &["branch", "--set-upstream-to", &tracking, &ours])?;
            }
            out.push_str("Pushed to origin\n");
        } else {
            out.push_str("Origin already has everything\n");
        }
    }
    if out.is_empty() {
        out.push_str("Already in sync\n");
    }
    Ok(out)
}
