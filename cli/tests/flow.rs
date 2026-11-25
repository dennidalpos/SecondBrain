//! End-to-end flow on a temporary home and a temporary Git repository.

use clap::Parser;
use secondbrain::cli::{Cli, run};
use secondbrain::mcp;
use secondbrain::store::Home;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn temp(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("sb-test-{name}-{}-{nanos}", std::process::id()));
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

fn sb_err(home: &Path, cwd: &Path, args: &[&str]) -> String {
    let mut argv = vec!["sb", "--home", home.to_str().unwrap()];
    argv.extend_from_slice(args);
    format!(
        "{:#}",
        run(Cli::try_parse_from(argv).unwrap(), cwd).unwrap_err()
    )
}

#[test]
fn init_add_tasks_context_unlink() {
    let home = temp("home");
    let repo = git_repo("git@github.com:Owner/Demo.git");
    fs::write(repo.join("AGENTS.md"), "# Demo\n\nOwn rules.\n").unwrap();

    assert!(sb_err(&home, &repo, &["task", "list"]).contains("sb init"));
    assert!(sb(&home, &repo, &["init"]).contains("SecondBrain is ready"));
    assert!(sb_err(&home, &repo, &["context"]).contains("sb add"));

    let added = sb(&home, &repo, &["add"]);
    assert!(added.contains("Added github.com/owner/demo"), "{added}");
    let agents = fs::read_to_string(repo.join("AGENTS.md")).unwrap();
    assert!(agents.starts_with("# Demo\n\nOwn rules.\n\n<!-- secondbrain:begin -->"));
    assert_eq!(
        fs::read_to_string(repo.join("CLAUDE.md")).unwrap(),
        "@AGENTS.md\n"
    );
    assert!(sb(&home, &repo, &["add"]).contains("Already added"));

    assert!(
        sb(&home, &repo, &["task", "add", "Write docs", "-p", "2"])
            .contains("#1 [todo] P2 Write docs")
    );
    sb(
        &home,
        &repo,
        &[
            "task",
            "add",
            "Ask the client",
            "--needs-user",
            "--body",
            "Call them.",
        ],
    );
    sb(&home, &repo, &["task", "set", "2", "--status", "doing"]);
    let list = sb(&home, &repo, &["task", "list"]);
    assert_eq!(
        list,
        "#2 [doing] Ask the client (needs you)\n#1 [todo] P2 Write docs\n"
    );
    assert!(sb(&home, &repo, &["task", "show", "2"]).contains("Call them."));
    sb(&home, &repo, &["task", "done", "1"]);
    assert!(!sb(&home, &repo, &["task", "list"]).contains("Write docs"));
    assert!(sb(&home, &repo, &["task", "list", "--all"]).contains("[done] P2 Write docs"));

    sb(&home, &repo, &["decide", "Use SQLite for local storage"]);
    let ctx = sb(&home, &repo, &["context"]);
    assert!(ctx.starts_with("# github.com/owner/demo"));
    assert!(ctx.contains("Use SQLite") && ctx.contains("## Open tasks (1)"));
    assert!(sb(&home, &repo, &["search", "sqlite"]).contains("decision"));
    assert!(sb(&home, &home, &["task", "--repo", "demo", "list"]).contains("Ask the client"));

    let unlinked = sb(&home, &repo, &["unlink"]);
    assert!(unlinked.contains("Unlinked"));
    assert_eq!(
        fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
        "# Demo\n\nOwn rules.\n"
    );
    assert!(!repo.join("CLAUDE.md").exists());
}

#[test]
fn migrate_is_idempotent() {
    let home = temp("home");
    sb(&home, &home, &["init"]);
    let export = home.join("export.json");
    fs::write(&export, json!({"repositories": [{
        "identity": "github.com/owner/old", "path": "D:/nowhere/old",
        "tasks": [{"id": "T-1", "title": "#7 - First", "status": "blocked", "priority": "P1", "execution": "user_required"}],
        "legacyTasks": [{"id": "L-1", "task": "Legacy plan item", "status": "planned"}]
    }]}).to_string()).unwrap();
    assert!(
        sb(&home, &home, &["migrate", export.to_str().unwrap()])
            .contains("2 tasks imported, 0 skipped")
    );
    assert!(
        sb(&home, &home, &["migrate", export.to_str().unwrap()])
            .contains("0 tasks imported, 2 skipped")
    );
    let list = sb(
        &home,
        &home,
        &["task", "--repo", "github.com/owner/old", "list"],
    );
    assert_eq!(
        list,
        "#2 [todo] Legacy plan item\n#1 [blocked] P1 First (needs you)\n"
    );
}

#[test]
fn mcp_round_trip() {
    let home_dir = temp("home");
    let repo = git_repo("https://github.com/owner/mcp.git");
    sb(&home_dir, &repo, &["init"]);
    sb(&home_dir, &repo, &["add", "--no-files"]);
    assert!(!repo.join("AGENTS.md").exists());
    let home = Home::resolve(Some(&home_dir)).unwrap();
    let call = |id: i64, method: &str, params: serde_json::Value| {
        mcp::handle(
            &home,
            &home_dir,
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
        )
        .unwrap()
    };

    let init = call(1, "initialize", json!({"protocolVersion": "2025-06-18"}));
    assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
    assert!(
        mcp::handle(
            &home,
            &home_dir,
            &json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
        )
        .is_none()
    );
    assert_eq!(
        call(2, "tools/list", json!({}))["result"]["tools"]
            .as_array()
            .unwrap()
            .len(),
        9
    );

    let tool = |id: i64, name: &str, args: serde_json::Value| {
        let r = call(id, "tools/call", json!({"name": name, "arguments": args}));
        (
            r["result"]["isError"].as_bool().unwrap(),
            r["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_string(),
        )
    };
    let (err, text) = tool(3, "get_context", json!({}));
    assert!(err && text.contains("pass a repository"), "{text}");
    let (err, text) = tool(
        4,
        "add_task",
        json!({"repo": "mcp", "title": "From chat", "priority": 1}),
    );
    assert!(!err && text.contains("#1 [todo] P1 From chat"), "{text}");
    let (err, _) = tool(
        5,
        "update_task",
        json!({"repo": "mcp", "id": 1, "status": "doing"}),
    );
    assert!(!err);
    let (_, text) = tool(6, "get_context", json!({"repo": "github.com/owner/mcp"}));
    assert!(text.contains("#1 [doing] P1 From chat"), "{text}");
    let (err, text) = tool(7, "update_task", json!({"repo": "mcp", "id": 1}));
    assert!(err && text.contains("nothing to change"));
    assert_eq!(call(8, "nope", json!({}))["error"]["code"], -32601);
}
