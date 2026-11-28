//! `sb check` end to end: surfaces, dossier text, ignore file, exit code and the pre-push hook.

use clap::Parser;
use secondbrain::cli::{Cli, Exit, run};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp(name: &str) -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!(
        "sb-check-{name}-{}-{nanos}-{n}",
        std::process::id()
    ));
    fs::create_dir_all(&p).unwrap();
    p
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// (exit code, printed text)
fn sb(home: &Path, cwd: &Path, args: &[&str]) -> (i32, String) {
    let mut argv = vec!["sb", "--home", home.to_str().unwrap()];
    argv.extend_from_slice(args);
    match run(Cli::try_parse_from(argv).unwrap(), cwd) {
        Ok(s) => (0, s),
        Err(e) => match e.downcast_ref::<Exit>() {
            Some(x) => (x.code, x.text.clone()),
            None => (1, format!("{e:#}")),
        },
    }
}

#[test]
fn check_reports_and_silences() {
    let home = temp("home");
    let repo = temp("repo");
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "Test"]);
    git(&repo, &["config", "user.email", "test@example.invalid"]);
    git(
        &repo,
        &[
            "remote",
            "add",
            "origin",
            "https://example.invalid/owner/checked.git",
        ],
    );
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(
        &home,
        &repo,
        &[
            "task",
            "add",
            "Renegotiate the hosting contract with the client",
        ],
    );

    fs::write(repo.join("README.md"), "# Demo\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "init"]);
    assert_eq!(sb(&home, &repo, &["check"]).0, 0);

    // A committed and then removed email stays in the unpushed history.
    let addr = ["mario.rossi", "studio-legale.it"].join("@");
    fs::write(repo.join("notes.txt"), format!("call {addr}\n")).unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "notes"]);
    fs::remove_file(repo.join("notes.txt")).unwrap();
    git(&repo, &["commit", "-q", "-am", "drop notes"]);
    // Dossier text in a working file (not committed yet).
    fs::write(
        repo.join("TODO.md"),
        "- renegotiate the hosting contract with the client\n",
    )
    .unwrap();

    let (code, text) = sb(&home, &repo, &["check"]);
    assert_eq!(code, 2, "{text}");
    assert!(text.contains("notes.txt:1  email (commit "), "{text}");
    assert!(text.contains("TODO.md:1  dossier-text"), "{text}");
    assert!(text.contains("2 finding(s)"), "{text}");

    // Silence both: one fingerprint in the ignore file, one inline marker.
    let fp = text
        .lines()
        .find(|l| l.contains("email"))
        .unwrap()
        .rsplit('[')
        .next()
        .unwrap()
        .trim_end_matches(']')
        .to_string();
    fs::write(
        repo.join(".sbcheck-ignore"),
        format!("{fp}  reviewed: public office address\n"),
    )
    .unwrap();
    fs::write(
        repo.join("TODO.md"),
        "- renegotiate the hosting contract with the client  sb-check: ignore\n",
    )
    .unwrap();
    let (code, text) = sb(&home, &repo, &["check"]);
    assert_eq!(code, 0, "{text}");
    assert!(text.starts_with("No findings"));

    // JSON output, and the hook: install, idempotent, refuses a foreign hook, uninstall.
    fs::write(
        repo.join("TODO.md"),
        "- renegotiate the hosting contract with the client\n",
    )
    .unwrap();
    let (code, json) = sb(&home, &repo, &["check", "--json"]);
    assert_eq!(code, 2);
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed[0]["rule"], "dossier-text");
    assert!(
        sb(&home, &repo, &["check", "--install-hook"])
            .1
            .contains("Installed")
    );
    assert!(
        sb(&home, &repo, &["check", "--install-hook"])
            .1
            .contains("already installed")
    );
    let hook = repo.join(".git/hooks/pre-push");
    assert!(
        fs::read_to_string(&hook)
            .unwrap()
            .contains("exec sb check --hook")
    );
    assert!(
        sb(&home, &repo, &["check", "--uninstall-hook"])
            .1
            .contains("Removed")
    );
    fs::write(&hook, "#!/bin/sh\necho mine\n").unwrap();
    let (code, err) = sb(&home, &repo, &["check", "--install-hook"]);
    assert_eq!(code, 1);
    assert!(err.contains("not written by sb"));
    assert_eq!(sb(&home, &repo, &["check", "--uninstall-hook"]).0, 1);
}

#[test]
fn checks_commit_messages_merge_results_and_new_ref_destination() {
    let home = temp("objects-home");
    let repo = temp("objects-repo");
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "Test"]);
    git(&repo, &["config", "user.email", "test@example.invalid"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "init"]);
    git(&repo, &["switch", "-q", "-c", "side"]);
    let email = ["mario.rossi", "studio-legale.it"].join("@");
    git(
        &repo,
        &[
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            &format!("Contact {email}"),
        ],
    );
    git(&repo, &["switch", "-q", "main"]);
    git(&repo, &["merge", "-q", "--no-commit", "--no-ff", "side"]);
    let name = "résolution finale.txt";
    let token = ["ghp_", &"a1B2c3D4e5F6g7H8i9J0".repeat(2)].concat();
    fs::write(repo.join(name), &token).unwrap();
    git(&repo, &["add", "--", name]);
    git(&repo, &["commit", "-q", "-m", "merge"]);
    git(&repo, &["rm", "-q", "--", name]);
    git(&repo, &["commit", "-q", "-m", "cleanup"]);

    let (code, report) = sb(&home, &repo, &["check", "--history"]);
    assert_eq!(code, 2, "{report}");
    assert!(report.contains("<commit message>:1  email"));
    assert!(report.contains(name));

    let head = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/unrelated/main", &head]);
    assert_eq!(sb(&home, &repo, &["check"]).0, 0);
    let mut hook = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&repo)
        .args(["--home", home.to_str().unwrap(), "check", "--hook"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(
        hook.stdin.take().unwrap(),
        "refs/heads/main {head} refs/heads/new {}",
        "0".repeat(40)
    )
    .unwrap();
    let output = hook.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(2), "{:?}", output);
}
