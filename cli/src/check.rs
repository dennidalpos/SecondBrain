//! `sb check`: scans what a push would publish for secrets, personal data and dossier text.
//!
//! Surfaces: the working tree (tracked and untracked, not ignored files) and the lines added
//! by the commits that are not on any remote yet (`--history`: every commit).
//! Silence a reviewed false positive with `sb-check: ignore` on the line, or with its
//! fingerprint and a reason in a tracked `.sbcheck-ignore` file at the repository root.

use crate::store::{Dossier, write_atomic};
use anyhow::{Context as _, Result, anyhow, bail};
use regex::Regex;
use serde::Serialize;
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

pub const IGNORE_FILE: &str = ".sbcheck-ignore";
pub const INLINE_IGNORE: &str = "sb-check: ignore";
const HOOK_MARKER: &str = "# Installed by `sb check --install-hook`.";
const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
const ZERO_SHA: &str = "0000000000000000000000000000000000000000";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Secret,
    Personal,
    Dossier,
}

#[derive(Clone, Debug, Serialize)]
pub struct Finding {
    pub rule: &'static str,
    pub kind: Kind,
    pub path: String,
    pub line: usize,
    /// `working`, or the short id of the commit that adds the line.
    pub surface: String,
    /// The matched text, shortened for secrets.
    pub excerpt: String,
    pub fingerprint: String,
}

struct Rule {
    name: &'static str,
    kind: Kind,
    re: Regex,
    /// Index of the capture group that holds the value; 0 is the whole match.
    group: usize,
}

fn rules() -> &'static [Rule] {
    static RULES: OnceLock<Vec<Rule>> = OnceLock::new();
    RULES.get_or_init(|| {
        let r = |name, kind, pattern: &str, group| Rule {
            name,
            kind,
            re: Regex::new(pattern).expect("valid rule pattern"),
            group,
        };
        vec![
            r("private-key", Kind::Secret, r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----", 0),
            r("aws-access-key", Kind::Secret, r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", 0),
            r("github-token", Kind::Secret, r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b", 0),
            r("anthropic-key", Kind::Secret, r"\bsk-ant-[A-Za-z0-9_-]{20,}", 0),
            r("openai-key", Kind::Secret, r"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}", 0),
            r("slack-token", Kind::Secret, r"\bxox[abprs]-[A-Za-z0-9-]{10,}", 0),
            r("google-api-key", Kind::Secret, r"\bAIza[0-9A-Za-z_-]{35}\b", 0),
            r("stripe-live-key", Kind::Secret, r"\b(?:sk|rk)_live_[0-9A-Za-z]{20,}", 0),
            r(
                "credential-assignment",
                Kind::Secret,
                r#"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|client[_-]?secret)\b["']?\s*[:=]\s*["']([^"'\s]{8,})["']"#,
                1,
            ),
            r("url-credentials", Kind::Secret, r"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+:([^/\s:@]{6,})@", 1),
            r("email", Kind::Personal, r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}", 0),
            r("home-path", Kind::Personal, r#"(?i)\b[A-Z]:[\\/]{1,2}Users[\\/]{1,2}([^\\/\s'"<>`|:*?,;()]+)"#, 1),
            r("home-path", Kind::Personal, r#"(?:^|[\s'"`(=])/(?:Users|home)/([^/\s'"<>`,;()]+)"#, 1),
        ]
    })
}

const PLACEHOLDERS: &[&str] = &[
    "example",
    "changeme",
    "change-me",
    "placeholder",
    "your",
    "xxx",
    "***",
    "...",
    "<",
    "${",
    "{{",
    "%",
    "$(",
    "redacted",
    "dummy",
    "sample",
    "secret",
    "password",
    "token",
    "test",
    "fake",
    "mock",
    "fixture",
    "synthetic",
];
const SAFE_EMAIL_DOMAINS: &[&str] = &[
    "example.com",
    "example.org",
    "example.net",
    "users.noreply.github.com",
    "noreply.github.com",
    "localhost",
];
const SAFE_EMAIL_SUFFIXES: &[&str] = &[".example", ".invalid", ".test", ".local", ".localhost"];
const GENERIC_USERS: &[&str] = &[
    "public",
    "default",
    "default user",
    "all users",
    "runner",
    "runneradmin",
    "user",
    "username",
    "you",
    "me",
    "name",
    "example",
    "someone",
    "home",
    "shared",
    "root",
    "ubuntu",
    "vscode",
    "codespace",
    "node",
    "app",
    "admin",
    "administrator",
    "workspace",
    "dev",
    "developer",
    "coder",
    "gitpod",
    "jovyan",
    "vagrant",
    "docker",
    "ec2-user",
    "pi",
    "<user>",
    "<username>",
    "$user",
    "%username%",
    "$env:username",
    "{user}",
    "*",
    "...",
];

fn is_placeholder(value: &str) -> bool {
    let v = value.to_lowercase();
    v.starts_with('$')
        || PLACEHOLDERS.iter().any(|p| v.contains(p))
        || v.chars().all(|c| c == v.chars().next().unwrap_or('x'))
}

/// What a scan knows beyond the line itself.
#[derive(Default)]
pub struct Scope {
    /// Dossier text that must not appear in the repository (lowercase).
    pub needles: Vec<String>,
    /// The repository folder name: `/home/<repo>` in a Dockerfile is the app user, not a person.
    pub repo: String,
}

/// License, notice and vendored data files: their contact addresses are public by design.
fn is_notice_file(path: &str) -> bool {
    let lower = path.to_lowercase();
    let name = lower.rsplit('/').next().unwrap_or_default();
    const NAMES: &[&str] = &[
        "license",
        "licence",
        "copying",
        "notice",
        "authors",
        "contributors",
        "maintainers",
        "credits",
        "third-party",
        "third_party",
        "thirdparty",
        "patents",
    ];
    const FILES: &[&str] = &[
        "package-lock.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        "cargo.lock",
        "go.sum",
        "composer.lock",
        "poetry.lock",
        "gemfile.lock",
        "public_suffix_list.dat",
    ];
    const DIRS: &[&str] = &[
        "vendor/",
        "node_modules/",
        "third_party/",
        "third-party/",
        "licenses/",
    ];
    NAMES.iter().any(|n| name.starts_with(n))
        || FILES.contains(&name)
        || DIRS
            .iter()
            .any(|d| lower.starts_with(d) || lower.contains(&format!("/{d}")))
}

/// Test code, where generic `password = "..."` values are fixtures.
fn is_test_path(path: &str) -> bool {
    let lower = path.to_lowercase();
    lower.split('/').any(|part| {
        matches!(
            part,
            "test" | "tests" | "spec" | "specs" | "__tests__" | "testdata" | "fixtures"
        ) || part.contains("_test.")
            || part.contains(".test.")
            || part.contains(".spec.")
            || part.starts_with("test_")
    })
}

/// Rule-specific exceptions for a match at `start..end` of `line` in `path`.
fn accepted(
    rule: &Rule,
    path: &str,
    scope: &Scope,
    line: &str,
    value: &str,
    start: usize,
    end: usize,
) -> bool {
    if rule.kind == Kind::Personal && is_notice_file(path) {
        return false;
    }
    match rule.name {
        "credential-assignment" if is_test_path(path) => false,
        "credential-assignment" | "url-credentials" => !is_placeholder(value),
        "email" => {
            let before = line[..start].chars().next_back();
            let after = line[end..].chars().next();
            // git@github.com:owner/name and https://user:token@host are addresses, not emails.
            if after == Some(':') || matches!(before, Some(':') | Some('/')) {
                return false;
            }
            let domain = value.rsplit('@').next().unwrap_or_default().to_lowercase();
            let local = value.split('@').next().unwrap_or_default().to_lowercase();
            !(SAFE_EMAIL_DOMAINS.contains(&domain.as_str())
                || SAFE_EMAIL_SUFFIXES.iter().any(|s| domain.ends_with(s))
                || local.contains("noreply")
                || local == "git")
        }
        "home-path" => {
            let name = value.to_lowercase();
            name.chars().count() >= 2
                && name.chars().next().is_some_and(char::is_alphanumeric)
                && name != scope.repo
                && !GENERIC_USERS.contains(&name.as_str())
        }
        _ => true,
    }
}

fn fnv(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{h:016x}")
}

fn excerpt(kind: Kind, text: &str) -> String {
    let short: String = text.chars().take(60).collect();
    match kind {
        Kind::Secret => format!("{}...", text.chars().take(4).collect::<String>()),
        _ if short.len() < text.len() => format!("{short}..."),
        _ => short,
    }
}

/// Text from the dossier that must not appear in the repository.
pub fn dossier_needles(d: &Dossier) -> Result<Vec<String>> {
    let mut needles = Vec::new();
    for (_, t) in d.task_files()? {
        if t.title.chars().count() >= 24 {
            needles.push(t.title.to_lowercase());
        }
    }
    let context = crate::store::read_optional(&d.dir.join("context.md"))?.unwrap_or_default();
    for line in context.lines() {
        let line = line.trim().trim_start_matches(['-', '*', '#', ' ']);
        if line.chars().count() >= 40 {
            needles.push(line.to_lowercase());
        }
    }
    for line in d.decisions()? {
        let text = line.trim_start_matches("- ");
        let text = text.split_once(": ").map_or(text, |(_, t)| t);
        if text.chars().count() >= 30 {
            needles.push(text.to_lowercase());
        }
    }
    needles.extend(crate::kb::needles(d));
    needles.sort();
    needles.dedup();
    Ok(needles)
}

/// Every finding on one line of `path`.
pub fn scan_line(
    path: &str,
    line_no: usize,
    line: &str,
    surface: &str,
    scope: &Scope,
) -> Vec<Finding> {
    let mut out = Vec::new();
    if line.contains(INLINE_IGNORE) {
        return out;
    }
    let mut seen = HashSet::new();
    for rule in rules() {
        for caps in rule.re.captures_iter(line) {
            let Some(m) = caps.get(rule.group) else {
                continue;
            };
            let whole = caps.get(0).expect("whole match");
            if !accepted(
                rule,
                path,
                scope,
                line,
                m.as_str(),
                whole.start(),
                whole.end(),
            ) {
                continue;
            }
            // A token matched by a specific rule is not reported again by a generic one.
            if rule.kind == Kind::Secret && !seen.insert((whole.start(), Kind::Secret)) {
                continue;
            }
            out.push(Finding {
                rule: rule.name,
                kind: rule.kind,
                path: path.to_string(),
                line: line_no,
                surface: surface.to_string(),
                excerpt: excerpt(rule.kind, m.as_str()),
                fingerprint: fnv(&format!("{}\0{path}\0{}", rule.name, m.as_str())),
            });
        }
    }
    if !scope.needles.is_empty() {
        let lower = line.to_lowercase();
        for n in &scope.needles {
            if lower.contains(n.as_str()) {
                out.push(Finding {
                    rule: "dossier-text",
                    kind: Kind::Dossier,
                    path: path.to_string(),
                    line: line_no,
                    surface: surface.to_string(),
                    excerpt: excerpt(Kind::Dossier, n),
                    fingerprint: fnv(&format!("dossier-text\0{path}\0{n}")),
                });
            }
        }
    }
    out
}

pub(crate) fn git_bytes(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("git")
        .arg("--no-replace-objects")
        .arg("-C")
        .arg(root)
        .args(["-c", "core.quotePath=false"])
        .args(args)
        .output()
        .with_context(|| format!("running git {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(out.stdout)
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8_lossy(&git_bytes(root, args)?).into_owned())
}

/// Formats that are binary or compressed even when the first bytes look like text.
const BINARY_EXTENSIONS: &[&str] = &[
    "pdf", "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tif", "tiff", "zip", "gz",
    "tgz", "7z", "rar", "jar", "docx", "xlsx", "pptx", "odt", "ods", "woff", "woff2", "ttf", "otf",
    "exe", "dll", "so", "dylib", "bin", "class", "pyc", "wasm", "mp3", "mp4", "mov", "avi",
    "sqlite", "db",
];

fn read_text(path: &Path) -> Option<String> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_lowercase();
    if BINARY_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    fs::File::open(path).ok()?.read_to_end(&mut bytes).ok()?;
    if bytes.iter().take(8192).any(|b| *b == 0) {
        return None;
    }
    Some(String::from_utf8_lossy(&bytes).into_owned())
}

fn scan_working(root: &Path, scope: &Scope, out: &mut Vec<Finding>) -> Result<usize> {
    let list = git(
        root,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
    )?;
    let mut files: Vec<&str> = list.split('\0').filter(|f| !f.is_empty()).collect();
    files.sort_unstable();
    files.dedup();
    let mut scanned = 0;
    for f in files {
        if f == IGNORE_FILE {
            continue;
        }
        let Some(text) = read_text(&root.join(f)) else {
            continue;
        };
        scanned += 1;
        for (i, line) in text.lines().enumerate() {
            out.extend(scan_line(f, i + 1, line, "working", scope));
        }
    }
    Ok(scanned)
}

/// Scan commit messages and Git blobs, including changes introduced by merges.
pub(crate) fn scan_git_commits(
    root: &Path,
    revs: &[&str],
    scope: &Scope,
    out: &mut Vec<Finding>,
) -> Result<usize> {
    let mut args = vec!["rev-list"];
    args.extend_from_slice(revs);
    let commits = git(root, &args)?;
    let mut count = 0;
    let mut seen = HashSet::new();
    for commit in commits.lines() {
        count += 1;
        let message = git_bytes(root, &["show", "-s", "--format=%B", commit])?;
        for (line, content) in String::from_utf8_lossy(&message).lines().enumerate() {
            out.extend(scan_line(
                "<commit message>",
                line + 1,
                content,
                commit,
                scope,
            ));
        }
        let changes = git_bytes(
            root,
            &[
                "diff-tree",
                "--root",
                "-m",
                "-r",
                "--no-commit-id",
                "--no-renames",
                "--no-abbrev",
                "--diff-filter=AMT",
                "-z",
                commit,
            ],
        )?;
        let mut fields = changes.split(|byte| *byte == 0);
        while let Some(header) = fields.next().filter(|header| !header.is_empty()) {
            let header = std::str::from_utf8(header)?;
            let mut parts = header.split_ascii_whitespace();
            let mode = parts.nth(1).context("missing Git object mode")?;
            let object = parts.nth(1).context("missing Git blob ID")?;
            let name = fields.next().context("missing Git path")?;
            if mode == "160000" || !seen.insert((name.to_vec(), object.to_string())) {
                continue;
            }
            let name = String::from_utf8_lossy(name);
            if name == IGNORE_FILE {
                continue;
            }
            let blob = git_bytes(root, &["cat-file", "blob", object])?;
            if blob.iter().take(8192).any(|byte| *byte == 0) {
                continue;
            }
            let text = String::from_utf8_lossy(&blob);
            for (line, content) in text.lines().enumerate() {
                out.extend(scan_line(&name, line + 1, content, commit, scope));
            }
        }
    }
    Ok(count)
}

/// Fingerprints listed in `.sbcheck-ignore` (first word of each line; `#` starts a comment).
pub fn ignored(root: &Path) -> HashSet<String> {
    fs::read_to_string(root.join(IGNORE_FILE))
        .unwrap_or_default()
        .lines()
        .map(|l| l.split('#').next().unwrap_or_default().trim())
        .filter_map(|l| l.split_whitespace().next())
        .map(str::to_lowercase)
        .collect()
}

pub struct Report {
    pub findings: Vec<Finding>,
    pub files: usize,
    pub commits: usize,
    pub dossier_checked: bool,
}

pub enum Range {
    /// Commits not on any remote.
    Unpushed,
    /// Every commit of every ref.
    History,
    /// Explicit git log arguments (from a pre-push hook).
    Revs(Vec<String>),
}

pub fn scan(root: &Path, dossier: Option<&Dossier>, range: &Range) -> Result<Report> {
    let scope = Scope {
        needles: dossier
            .map(dossier_needles)
            .transpose()?
            .unwrap_or_default(),
        repo: root
            .file_name()
            .map(|n| n.to_string_lossy().to_lowercase())
            .unwrap_or_default(),
    };
    let mut raw = Vec::new();
    let files = scan_working(root, &scope, &mut raw)?;
    let revs: Vec<String> = match range {
        Range::Unpushed => {
            let has_head = git(root, &["rev-parse", "--verify", "-q", "HEAD"]).is_ok();
            if has_head {
                vec!["HEAD".into(), "--not".into(), "--remotes".into()]
            } else {
                Vec::new()
            }
        }
        Range::History => vec!["--all".into()],
        Range::Revs(r) => r.clone(),
    };
    let commits = if revs.is_empty() {
        0
    } else if matches!(range, Range::Revs(_)) {
        let mut count = 0;
        for rev in &revs {
            // A remote tip might not exist locally. Scan the complete local side in that case.
            let revision = if let Some((base, head)) = rev.split_once("..") {
                if git(root, &["cat-file", "-e", base]).is_ok() {
                    rev.as_str()
                } else {
                    head
                }
            } else {
                rev.as_str()
            };
            count += scan_git_commits(root, &[revision], &scope, &mut raw)?;
        }
        count
    } else {
        scan_git_commits(
            root,
            &revs.iter().map(String::as_str).collect::<Vec<_>>(),
            &scope,
            &mut raw,
        )?
    };

    let skip = ignored(root);
    let mut seen = HashSet::new();
    let findings = raw
        .into_iter()
        .filter(|f| !skip.contains(&f.fingerprint))
        .filter(|f| seen.insert((f.fingerprint.clone(), f.surface == "working")))
        .collect();
    Ok(Report {
        findings,
        files,
        commits,
        dossier_checked: dossier.is_some(),
    })
}

pub fn report_text(r: &Report) -> String {
    let mut s = String::new();
    for f in &r.findings {
        let place = if f.surface == "working" {
            String::new()
        } else {
            format!(" (commit {})", f.surface)
        };
        s.push_str(&format!(
            "{}:{}  {}{}  {}  [{}]\n",
            f.path, f.line, f.rule, place, f.excerpt, f.fingerprint
        ));
    }
    let dossier = if r.dossier_checked {
        ""
    } else {
        "; dossier text not checked (repository not added)"
    };
    if r.findings.is_empty() {
        s.push_str(&format!(
            "No findings in {} files and {} commit(s){dossier}.\n",
            r.files, r.commits
        ));
    } else {
        s.push_str(&format!(
            "\n{} finding(s) in {} files and {} commit(s){dossier}.\n\
             Fix them, or for a reviewed false positive add `{INLINE_IGNORE}` to the line or the fingerprint and a reason to {IGNORE_FILE}.\n\
             A secret already committed stays in history: rotate it, then rewrite the unpushed commits.\n",
            r.findings.len(),
            r.files,
            r.commits
        ));
    }
    s
}

fn is_zero_oid(oid: &str) -> bool {
    oid == ZERO_SHA || oid.len() == 64 && oid.bytes().all(|b| b == b'0')
}

/// Revision arguments for the refs a pre-push hook receives on standard input.
pub fn hook_revs(stdin: &str) -> Vec<String> {
    let mut revs = Vec::new();
    for line in stdin.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        let oid = |value: &str| {
            matches!(value.len(), 40 | 64) && value.bytes().all(|c| c.is_ascii_hexdigit())
        };
        if parts.len() < 4 || !oid(parts[1]) || !oid(parts[3]) || is_zero_oid(parts[1]) {
            continue;
        }
        let (local, remote) = (parts[1], parts[3]);
        if is_zero_oid(remote) {
            revs.push(local.to_string());
        } else {
            revs.push(format!("{remote}..{local}"));
        }
    }
    revs
}

fn hook_path(root: &Path) -> Result<PathBuf> {
    let p = git(root, &["rev-parse", "--git-path", "hooks/pre-push"])?;
    let p = PathBuf::from(p.trim());
    Ok(if p.is_absolute() { p } else { root.join(p) })
}

pub(crate) fn hook_status(root: &Path) -> &'static str {
    match hook_path(root).map(fs::read_to_string) {
        Ok(Ok(text)) if text.contains(HOOK_MARKER) => "SecondBrain hook installed",
        Ok(Ok(_)) => "custom hook present",
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            "optional hook not installed"
        }
        _ => "hook could not be checked",
    }
}

pub fn install_hook(root: &Path) -> Result<String> {
    let path = hook_path(root)?;
    if let Ok(existing) = fs::read_to_string(&path) {
        if existing.contains(HOOK_MARKER) {
            return Ok(format!(
                "The pre-push hook is already installed: {}\n",
                path.display()
            ));
        }
        bail!(
            "{} already exists and was not written by sb; add `sb check --hook` to it yourself",
            path.display()
        );
    }
    write_atomic(
        &path,
        &format!(
            "#!/bin/sh\n{HOOK_MARKER}\n# Blocks the push when `sb check` reports findings.\nexec sb check --hook\n"
        ),
    )?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755))?;
    }
    Ok(format!("Installed the pre-push hook: {}\n", path.display()))
}

pub fn uninstall_hook(root: &Path) -> Result<String> {
    let path = hook_path(root)?;
    match fs::read_to_string(&path) {
        Ok(text) if text.contains(HOOK_MARKER) => {
            fs::remove_file(&path)?;
            Ok(format!("Removed the pre-push hook: {}\n", path.display()))
        }
        Ok(_) => Err(anyhow!(
            "{} was not written by sb; it stays",
            path.display()
        )),
        Err(_) => Ok("No pre-push hook installed.\n".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules_on(line: &str) -> Vec<&'static str> {
        scan_line("f.txt", 1, line, "working", &Scope::default())
            .into_iter()
            .map(|f| f.rule)
            .collect()
    }

    /// Joins pieces at run time, so this file never holds a whole sample and `sb check` stays quiet on it.
    fn j(parts: &[&str]) -> String {
        parts.concat()
    }

    #[test]
    fn secrets() {
        assert_eq!(
            rules_on(&j(&["-----BEGIN OPENSSH PRI", "VATE KEY-----"])),
            ["private-key"]
        );
        assert_eq!(
            rules_on(&j(&["key = AKIA", "ABCDEFGHIJKLMNOP"])),
            ["aws-access-key"]
        );
        assert_eq!(
            rules_on(&format!("t=ghp_{}", "a".repeat(36))),
            ["github-token"]
        );
        assert_eq!(
            rules_on(&format!("k: sk-ant-api03-{}", "b1".repeat(20))),
            ["anthropic-key"]
        );
        assert_eq!(
            rules_on(&j(&[r#"password = "hunter2"#, r#"hunter2""#])),
            ["credential-assignment"]
        );
        assert!(rules_on(r#"password = "${DB_PASSWORD}""#).is_empty());
        assert!(rules_on(r#"api_key: "your-api-key-here""#).is_empty());
        assert_eq!(
            rules_on(&j(&["https://bob:s3cr3t", "Value@host", ".io/x"])),
            ["url-credentials"]
        );
        assert!(rules_on("https://user:tok@github.com/owner/name").is_empty());
    }

    #[test]
    fn personal_data() {
        let email = j(&["mario.rossi", "@", "studio.it"]);
        assert_eq!(rules_on(&format!("contact {email}")), ["email"]);
        assert!(rules_on("git@github.com:owner/name.git").is_empty());
        assert!(rules_on("test@example.invalid and 1+bot@users.noreply.github.com").is_empty());
        assert_eq!(rules_on(&j(&[r"C:\Us", r"ers\Mario\repo"])), ["home-path"]);
        assert_eq!(rules_on(&j(&["see /ho", "me/mario/x"])), ["home-path"]);
        assert!(rules_on(r"C:\Users\Public\x and /home/runner/work").is_empty());
        assert!(rules_on(&format!("{email}  {INLINE_IGNORE}")).is_empty());
    }

    #[test]
    fn dossier_text_and_fingerprints() {
        let needles = Scope {
            needles: vec!["migrate the billing export to v2".to_string()],
            repo: String::new(),
        };
        let f = scan_line(
            "README.md",
            3,
            "TODO: Migrate the billing export to v2 soon",
            "working",
            &needles,
        );
        assert_eq!(f.len(), 1);
        assert_eq!((f[0].rule, f[0].kind), ("dossier-text", Kind::Dossier));
        let again = scan_line(
            "README.md",
            9,
            "Migrate the billing export to v2",
            "abc1234",
            &needles,
        );
        assert_eq!(again[0].fingerprint, f[0].fingerprint);
    }

    #[test]
    fn notice_test_and_app_user_exceptions() {
        let scope = Scope {
            needles: Vec::new(),
            repo: "shopapp".into(),
        };
        let on = |path: &str, line: &str| -> Vec<&'static str> {
            scan_line(path, 1, line, "working", &scope)
                .into_iter()
                .map(|f| f.rule)
                .collect()
        };
        let email = j(&["jane.doe", "@", "studio.it"]);
        let key = j(&["AKIA", "ABCDEFGHIJKLMNOP"]);
        // Contact addresses in license and vendored files are public; secrets are not.
        assert!(on("THIRD-PARTY-NOTICES.txt", &email).is_empty());
        assert!(on("src/vendor/lib/AUTHORS", &email).is_empty());
        assert!(on("data/public_suffix_list.dat", &email).is_empty());
        assert_eq!(on("LICENSE", &key), ["aws-access-key"]);
        assert_eq!(on("src/app.rs", &email), ["email"]);
        // Generic credential values in tests are fixtures; real token formats still count.
        let assignment = j(&[r#"password = "hunter2"#, r#"hunter2""#]);
        assert!(on("tests/login_test.go", &assignment).is_empty());
        assert!(on("src/auth.spec.ts", &assignment).is_empty());
        assert_eq!(on("src/config.rs", &assignment), ["credential-assignment"]);
        assert!(on("src/config.rs", r#"token = "$OPENAI_API_KEY_VALUE""#).is_empty());
        // The app's own user in a container, and fragments that are not names.
        assert!(on("Dockerfile", &j(&["WORKDIR /ho", "me/shopapp/app"])).is_empty());
        assert!(on("setup.md", &j(&["cd /ho", "me/workspace/x"])).is_empty());
        assert_eq!(
            on("a.md", &j(&["see /ho", "me/mario, then"])),
            ["home-path"]
        );
        assert!(on("x.ts", "join('/home/', u)").is_empty());
        assert_eq!(
            on("Dockerfile", &j(&["COPY . /ho", "me/mario/app"])),
            ["home-path"]
        );
    }

    #[test]
    fn pre_push_ranges() {
        let a = "a".repeat(40);
        let b = "b".repeat(40);
        let input = format!(
            "refs/heads/x {a} refs/heads/x {b}\nrefs/heads/new {a} refs/heads/new {ZERO_SHA}\nrefs/heads/gone {ZERO_SHA} refs/heads/gone {b}\n"
        );
        assert_eq!(hook_revs(&input), vec![format!("{b}..{a}"), a]);
    }
}
