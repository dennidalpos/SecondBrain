//! `sb doctor` on a temporary home, temporary repositories and temporary client folders.

use clap::Parser;
use secondbrain::cli::{Cli, run};
use secondbrain::doctor::{self, Options, State};
use secondbrain::mcp_install::{Dirs, Launch};
use secondbrain::store::Home;
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
    let p = std::env::temp_dir().join(format!("sb-doc-{name}-{}-{nanos}-{n}", std::process::id()));
    fs::create_dir_all(&p).unwrap();
    p
}

fn git_repo(remote: &str) -> PathBuf {
    let p = temp("repo");
    let git = |args: &[&str]| {
        assert!(
            Command::new("git")
                .arg("-C")
                .arg(&p)
                .args(args)
                .status()
                .unwrap()
                .success()
        )
    };
    git(&["init", "-q"]);
    git(&["remote", "add", "origin", remote]);
    p
}

fn sb(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let mut argv = vec!["sb", "--home", home.to_str().unwrap()];
    argv.extend_from_slice(args);
    run(Cli::try_parse_from(argv).unwrap(), cwd).unwrap()
}

fn check(home: &Path, dirs: &Dirs, fix: bool) -> Vec<doctor::Finding> {
    let launch = Launch {
        command: std::env::current_exe().unwrap().display().to_string(),
        sb_home: Some(home.display().to_string()),
    };
    doctor::run(
        &Home {
            root: home.to_path_buf(),
        },
        &Options {
            fix,
            launch: &launch,
            dirs,
            external: false,
        },
    )
    .unwrap()
}

fn dirs() -> Dirs {
    let home = temp("user");
    Dirs {
        config: home.join("config"),
        local: None,
        home,
    }
}

#[test]
fn finds_a_packaged_claude_desktop_registration() {
    let mut dirs = dirs();
    let local = dirs.home.join("local");
    dirs.local = Some(local.clone());
    let config =
        local.join("Packages/Claude_test/LocalCache/Roaming/Claude/claude_desktop_config.json");
    fs::create_dir_all(config.parent().unwrap()).unwrap();
    fs::write(
        &config,
        r#"{"mcpServers":{"secondbrain":{"command":"sb","args":["mcp"]}}}"#,
    )
    .unwrap();
    let client = secondbrain::mcp_install::find("claude-desktop").unwrap();
    assert_eq!(
        secondbrain::mcp_install::config_path(&client, &dirs),
        Some(config)
    );
    assert_eq!(
        secondbrain::mcp_install::registered(&client, &dirs, false),
        Some(("sb".into(), None))
    );
}

#[test]
fn clean_setup_has_no_findings() {
    let home = temp("home");
    let repo = git_repo("https://github.com/acme/clean.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    assert!(check(&home, &dirs(), false).is_empty());
}

#[test]
fn forgets_missing_checkouts_and_rewrites_stale_blocks() {
    let home = temp("home");
    let repo = git_repo("https://github.com/acme/drift.git");
    let gone = git_repo("https://github.com/acme/drift.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    sb(&home, &gone, &["add"]);
    fs::remove_dir_all(&gone).unwrap();
    fs::remove_file(repo.join("CLAUDE.md")).unwrap();
    fs::write(
        home.join("rules.md"),
        "# Rules\n\n- A new rule that the linked block does not have yet.\n",
    )
    .unwrap();
    let d = dirs();

    let before = fs::read_to_string(repo.join("AGENTS.md")).unwrap();
    let found = check(&home, &d, false);
    assert_eq!(found.len(), 3, "{found:?}");
    assert!(found.iter().all(|f| f.state == State::Fixable));
    assert_eq!(fs::read_to_string(repo.join("AGENTS.md")).unwrap(), before);
    assert!(!repo.join("CLAUDE.md").exists());

    let fixed = check(&home, &d, true);
    assert!(fixed.iter().all(|f| f.state == State::Fixed), "{fixed:?}");
    assert!(
        fs::read_to_string(repo.join("AGENTS.md"))
            .unwrap()
            .contains("A new rule")
    );
    assert_eq!(
        fs::read_to_string(repo.join("CLAUDE.md")).unwrap().trim(),
        "@AGENTS.md"
    );
    assert!(check(&home, &d, false).is_empty());
}

#[test]
fn reports_what_needs_a_decision() {
    let home = temp("home");
    let repo = git_repo("https://github.com/acme/moved.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args([
            "remote",
            "set-url",
            "origin",
            "https://github.com/acme/renamed.git",
        ])
        .status()
        .unwrap();
    let found = check(&home, &dirs(), true);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].state, State::Manual);
    assert!(found[0].text.contains("github.com/acme/renamed"));
    assert!(doctor::unresolved(&found));
}

#[test]
fn repairs_an_mcp_entry_that_points_nowhere() {
    let home = temp("home");
    let repo = git_repo("https://github.com/acme/mcp.git");
    sb(&home, &repo, &["init"]);
    let d = dirs();
    let file = d.config.join("Claude").join("claude_desktop_config.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let stale = temp("missing").join("old");
    fs::write(
        &file,
        format!(
            r#"{{"mcpServers":{{"secondbrain":{{"command":"C:/nowhere/sb.exe","args":["mcp"],"env":{{"SB_HOME":{}}}}},"other":{{"command":"x"}}}}}}"#,
            serde_json::to_string(&stale.display().to_string()).unwrap()
        ),
    )
    .unwrap();

    let found = check(&home, &d, false);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].state, State::Fixable);

    let fixed = check(&home, &d, true);
    assert!(fixed.iter().all(|f| f.state == State::Fixed), "{fixed:?}");
    let text = fs::read_to_string(&file).unwrap();
    assert!(text.contains("\"other\""), "other servers are kept");
    assert!(!text.contains("nowhere"));
    assert!(check(&home, &d, false).is_empty());
}

#[test]
fn renumbers_a_duplicate_task_id() {
    let home = temp("home");
    let repo = git_repo("https://github.com/acme/dup.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    sb(&home, &repo, &["task", "add", "First"]);
    let tasks = fs::read_dir(home.join("repos"))
        .unwrap()
        .map(|e| e.unwrap().path().join("tasks"))
        .find(|p| p.is_dir())
        .unwrap();
    let first = fs::read_dir(&tasks)
        .unwrap()
        .map(|e| e.unwrap().path())
        .find(|p| p.extension().is_some_and(|e| e == "md"))
        .unwrap();
    let text = fs::read_to_string(&first).unwrap();
    fs::write(
        tasks.join("0001-second.md"),
        text.lines()
            .filter(|line| !line.starts_with("task_key:"))
            .collect::<Vec<_>>()
            .join("\n")
            .replace("First", "Second"),
    )
    .unwrap();
    let d = dirs();

    let found = check(&home, &d, false);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].state, State::Fixable);
    assert!(tasks.join("0001-second.md").exists());

    let fixed = check(&home, &d, true);
    assert!(fixed.iter().all(|f| f.state == State::Fixed), "{fixed:?}");
    let data = Home { root: home.clone() };
    let records = data
        .resolve_repo(None, &repo)
        .unwrap()
        .task_files()
        .unwrap();
    assert_eq!(
        records.iter().map(|(_, task)| task.id).collect::<Vec<_>>(),
        [1, 2]
    );
    assert!(
        tasks.join("0001-second.md").exists(),
        "a task's file identity stays fixed"
    );
    assert!(check(&home, &d, false).is_empty());
}

#[test]
fn refuses_to_guess_an_ambiguous_legacy_dependency() {
    let home = Home {
        root: temp("ambiguous-home"),
    };
    home.init().unwrap();
    let repo = git_repo("https://example.invalid/fixtures/ambiguous.git");
    let d = home.create("example.invalid/fixtures/ambiguous").unwrap();
    let mut files = Vec::new();
    for (file, id, title, dependency) in [
        ("a.md", 1, "First", ""),
        ("b.md", 1, "Second", ""),
        ("c.md", 2, "Dependent", "blocked_by: 1\n"),
    ] {
        let text = format!("---\nid: {id}\ntitle: {title}\n{dependency}---\n");
        let path = d.tasks_dir().join(file);
        fs::write(&path, &text).unwrap();
        files.push((path, text));
    }
    assert!(sb(&home.root, &repo, &["start"]).contains("ambiguous legacy blocker"));
    assert!(d.ready_tasks().is_err());
    assert!(
        d.renumber_duplicates()
            .unwrap_err()
            .to_string()
            .contains("ambiguous legacy blocker")
    );
    for (path, text) in files {
        assert_eq!(fs::read_to_string(path).unwrap(), text);
    }
}
