//! `sb run` with a fake agent script: branch, commits, task outcomes, refusals.

use secondbrain::run::{self, RunOptions};
use secondbrain::store::Home;
use secondbrain::task::Status;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

fn temp(name: &str) -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("sb-run-{name}-{}-{nanos}-{n}", std::process::id()));
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

/// `fake write|nowrite <result words>`: reads the prompt, maybe edits work.txt, prints the result line.
fn fake_agent(dir: &Path) -> PathBuf {
    if cfg!(windows) {
        let p = dir.join("fake.cmd");
        fs::write(
            &p,
            "@echo off\r\nmore >nul\r\nif \"%1\"==\"write\" echo changed by fake>> work.txt\r\necho SB-RESULT: %2 %3 %4 %5\r\n",
        )
        .unwrap();
        p
    } else {
        let p = dir.join("fake.sh");
        fs::write(
            &p,
            "#!/bin/sh\ncat >/dev/null\nmode=$1\nshift\n[ \"$mode\" = write ] && echo 'changed by fake' >> work.txt\necho \"SB-RESULT: $*\"\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        }
        p
    }
}

fn opts(agent_cmd: Option<String>) -> RunOptions {
    RunOptions {
        agent: None,
        agent_cmd,
        task: None,
        limit: None,
        timeout_minutes: 1,
        dry_run: false,
    }
}

#[test]
fn run_commits_done_work_on_its_own_branch() {
    let home_dir = temp("home");
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
            "https://example.invalid/owner/runner.git",
        ],
    );
    fs::write(repo.join("README.md"), "demo\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "init"]);

    let home = Home::resolve(Some(&home_dir)).unwrap();
    home.init().unwrap();
    let (d, _) = home.find_or_create("example.invalid/owner/runner").unwrap();
    d.add_task("Do A", "Write work.txt", Some(1), false)
        .unwrap();
    d.add_task("Needs input", "", Some(1), true).unwrap();
    d.add_task("Do B", "", Some(2), false).unwrap();

    let agent = fake_agent(&temp("agent"));
    let cmd = |args: &str| Some(format!("\"{}\" {args}", agent.display()));
    let mut lines = Vec::new();

    // Dry run: needs-you tasks are left out.
    let plan = run::run(
        &home,
        &repo,
        RunOptions {
            dry_run: true,
            ..opts(None)
        },
        &mut |l| lines.push(l.to_string()),
    )
    .unwrap();
    assert!(plan.contains("#1 [todo] P1 Do A") && plan.contains("#3 [todo] P2 Do B"));
    assert!(!plan.contains("Needs input"));

    // A dirty tree is refused.
    fs::write(repo.join("dirty.txt"), "x").unwrap();
    let err = run::run(&home, &repo, opts(cmd("write done")), &mut |_| {}).unwrap_err();
    assert!(format!("{err:#}").contains("uncommitted"));
    fs::remove_file(repo.join("dirty.txt")).unwrap();

    // Done with changes: one commit on a new sb/run-* branch; main is untouched.
    let main_head = git(&repo, &["rev-parse", "main"]);
    let out = run::run(
        &home,
        &repo,
        RunOptions {
            limit: Some(1),
            ..opts(cmd("write done"))
        },
        &mut |l| lines.push(l.to_string()),
    )
    .unwrap();
    let branch = git(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]);
    assert!(branch.starts_with(run::BRANCH_PREFIX), "{branch}");
    assert_eq!(git(&repo, &["rev-parse", "main"]), main_head);
    assert_eq!(git(&repo, &["log", "-1", "--format=%s"]), "Do A (sb #1)");
    assert!(
        out.contains("#1 done; commit") && out.contains("nothing pushed"),
        "{out}"
    );
    let t1 = d.task(1).unwrap();
    assert_eq!(t1.status, Status::Done);
    assert!(t1.body.contains("## sb run") && t1.body.contains("Log:"));

    // Blocked without changes: no commit, reason recorded, same branch reused.
    let before = git(&repo, &["rev-parse", "HEAD"]);
    let out = run::run(
        &home,
        &repo,
        opts(cmd("nowrite blocked missing key")),
        &mut |_| {},
    )
    .unwrap();
    assert_eq!(git(&repo, &["rev-parse", "--abbrev-ref", "HEAD"]), branch);
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), before);
    assert!(
        out.contains("#3 blocked: missing key; no file changed"),
        "{out}"
    );
    assert_eq!(d.task(3).unwrap().status, Status::Blocked);
    assert_eq!(d.task(2).unwrap().status, Status::Todo);

    // Failed with changes: committed as not done.
    d.add_task("Do C", "", None, false).unwrap();
    let out = run::run(&home, &repo, opts(cmd("write")), &mut |_| {}).unwrap();
    assert!(
        out.contains("#4 failed: the agent gave no SB-RESULT line; commit"),
        "{out}"
    );
    assert_eq!(
        git(&repo, &["log", "-1", "--format=%s"]),
        "Not done: Do C (sb #4)"
    );

    // A needs-you task is refused even when asked for by id; nothing left to run.
    let err = run::run(
        &home,
        &repo,
        RunOptions {
            task: Some(2),
            ..opts(cmd("write done"))
        },
        &mut |_| {},
    )
    .unwrap_err();
    assert!(format!("{err:#}").contains("needs you"));
    let out = run::run(&home, &repo, opts(cmd("write done")), &mut |_| {}).unwrap();
    assert!(out.contains("Nothing to do"));
    assert!(
        lines
            .iter()
            .any(|l| l.starts_with("Created branch sb/run-"))
    );
}
