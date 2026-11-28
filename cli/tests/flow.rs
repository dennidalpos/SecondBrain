//! End-to-end flow on a temporary home and a temporary Git repository.

use clap::Parser;
use secondbrain::cli::{Cli, run};
use secondbrain::mcp;
use secondbrain::store::Home;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// A new, empty folder per call. The counter keeps parallel tests apart where the
/// clock is coarse (macOS reports microseconds).
fn temp(name: &str) -> PathBuf {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let p = std::env::temp_dir().join(format!("sb-test-{name}-{}-{nanos}-{n}", std::process::id()));
    assert!(
        !p.exists(),
        "temporary folder already exists: {}",
        p.display()
    );
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
    assert!(agents.contains("include the full result in the first reply after execution"));
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
fn archive_moves_old_done_tasks_and_decisions_and_stays_searchable() {
    let home = temp("home");
    let repo = git_repo("git@github.com:Owner/Demo.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    sb(&home, &repo, &["task", "add", "Old chore"]);
    sb(&home, &repo, &["task", "add", "Old base"]);
    sb(
        &home,
        &repo,
        &["task", "add", "Needs the base", "--blocked-by", "2"],
    );
    sb(&home, &repo, &["task", "add", "Fresh chore"]);
    for id in ["1", "2", "4"] {
        sb(&home, &repo, &["task", "done", id]);
    }
    sb(&home, &repo, &["decide", "Recent choice"]);

    let dossier = fs::read_dir(home.join("repos"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    for entry in fs::read_dir(dossier.join("tasks")).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        if name.starts_with("0001") || name.starts_with("0002") {
            let text = fs::read_to_string(&path).unwrap();
            let old: Vec<String> = text
                .lines()
                .map(|l| {
                    if l.starts_with("updated: ") {
                        "updated: 2020-01-01".to_string()
                    } else {
                        l.to_string()
                    }
                })
                .collect();
            fs::write(&path, old.join("\n") + "\n").unwrap();
        }
    }
    let mut decisions = fs::read_to_string(dossier.join("decisions.md")).unwrap();
    decisions.push_str("- 2020-02-02: Use the zebra protocol\n");
    fs::write(dossier.join("decisions.md"), decisions).unwrap();

    let out = sb(&home, &repo, &["task", "archive", "--older-than", "30"]);
    assert!(
        out.contains("Archived 1 done task(s) and 1 decision(s)"),
        "{out}"
    );
    assert!(
        out.contains("Old chore") && out.contains("Kept 1 done task(s)"),
        "{out}"
    );

    let list = sb(&home, &repo, &["task", "list", "--all"]);
    assert!(!list.contains("Old chore"), "{list}");
    assert!(
        list.contains("Old base") && list.contains("Fresh chore"),
        "{list}"
    );
    assert_eq!(
        fs::read_dir(dossier.join("tasks-archive")).unwrap().count(),
        1
    );

    let kept = fs::read_to_string(dossier.join("decisions.md")).unwrap();
    assert!(
        kept.contains("Recent choice") && !kept.contains("zebra"),
        "{kept}"
    );
    assert!(
        kept.contains("Archived decisions: 1 in decisions-archive.md"),
        "{kept}"
    );
    let archived = fs::read_to_string(dossier.join("decisions-archive.md")).unwrap();
    assert!(
        archived.contains("- 2020-02-02: Use the zebra protocol"),
        "{archived}"
    );

    assert!(sb(&home, &repo, &["search", "zebra"]).contains("zebra"));
    assert!(sb(&home, &repo, &["search", "chore"]).contains("Old chore"));
    assert!(sb(&home, &repo, &["task", "add", "Next"]).contains("#5"));

    let again = sb(&home, &repo, &["task", "archive", "--older-than", "30"]);
    assert!(
        again.contains("Archived 0 done task(s) and 0 decision(s)"),
        "{again}"
    );
    assert!(
        fs::read_to_string(dossier.join("decisions.md"))
            .unwrap()
            .contains("Recent choice")
    );
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
fn generated_mcp_config_resolves_a_relative_home_for_the_client() {
    let directory = temp("relative-mcp-home");
    let output = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&directory)
        .args([
            "--home",
            "relative-home",
            "mcp",
            "config",
            "--client",
            "cursor",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());
    let out = String::from_utf8(output.stdout).unwrap();
    let (_, snippet) = out.split_once('\n').expect("configuration snippet");
    let config: serde_json::Value = serde_json::from_str(snippet).unwrap();
    let home = Path::new(
        config["mcpServers"]["secondbrain"]["env"]["SB_HOME"]
            .as_str()
            .unwrap(),
    );
    assert_eq!(home.file_name().unwrap(), "relative-home");
    assert_eq!(
        home.parent().unwrap().canonicalize().unwrap(),
        directory.canonicalize().unwrap(),
    );
}

#[test]
fn mcp_install_respects_the_devin_config_home() {
    let directory = temp("devin-config-home");
    let output = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&directory)
        .env("DEVIN_CONFIG_HOME", directory.join("profile"))
        .args(["--home", "data", "mcp", "install", "--client", "devin"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output);
    let registration = fs::read_to_string(directory.join("profile/devin/mcp_config.json")).unwrap();
    let config: serde_json::Value = serde_json::from_str(&registration).unwrap();
    assert_eq!(config["mcpServers"]["secondbrain"]["args"], json!(["mcp"]));
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
        25
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

    sb(
        &home_dir,
        &repo,
        &["task", "add", "First", "--accept", "cargo check"],
    );
    sb(
        &home_dir,
        &repo,
        &["task", "add", "Next", "--blocked-by", "2"],
    );
    let (_, text) = tool(9, "get_task", json!({"repo":"mcp","id":2}));
    assert!(text.contains("Acceptance command: cargo check"), "{text}");
    let (_, text) = tool(10, "ready_tasks", json!({"repo":"mcp"}));
    assert!(text.contains("#2 [todo]") && !text.contains("#3"), "{text}");
    let (err, _) = tool(
        11,
        "claim_task",
        json!({"repo":"mcp","id":2,"by":"in-chat"}),
    );
    assert!(!err);
    for name in ["update_task", "release_task"] {
        let (err, text) = tool(
            12,
            name,
            json!({"repo":"mcp","id":2,"by":"other","status":"done"}),
        );
        assert!(
            err && text.contains("no active claim held by other"),
            "{text}"
        );
    }
    let (err, _) = tool(
        13,
        "update_task",
        json!({"repo":"mcp","id":2,"by":"in-chat","status":"done"}),
    );
    assert!(!err);
    let (_, text) = tool(14, "ready_tasks", json!({"repo":"mcp"}));
    assert!(text.contains("#3 [todo]") && !text.contains("#2"), "{text}");
}

#[test]
fn mcp_can_onboard_a_checkout_and_preserve_initial_context_on_retries() {
    let home = Home {
        root: temp("initial-dossier").join("empty-home"),
    };
    let repo = git_repo("https://example.invalid/fixtures/onboarding.git");
    let agents = repo.join("AGENTS.md");
    fs::write(&agents, "# Checkout rules\n").unwrap();
    let call = |name: &str, args: serde_json::Value| {
        mcp::handle(
            &home,
            &home.root,
            &json!({
                "jsonrpc":"2.0", "id":1, "method":"tools/call",
                "params":{"name":name, "arguments":args},
            }),
        )
        .unwrap()["result"]
            .clone()
    };
    assert_eq!(
        call("link_repo", json!({"path":"relative"}))["isError"],
        true
    );
    assert!(!home.root.exists());
    let first = call("link_repo", json!({"path":repo}));
    assert_eq!(first["isError"], false, "{first}");
    assert!(
        first["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("guide onboarding")
    );
    assert_eq!(fs::read_to_string(&agents).unwrap(), "# Checkout rules\n");
    assert!(!repo.join("CLAUDE.md").exists());
    let set = call(
        "set_context",
        json!({"repo":"onboarding", "text":"Verified checkout findings", "if_empty":true}),
    );
    assert_eq!(set["isError"], false, "{set}");
    let retry = call(
        "set_context",
        json!({"repo":"onboarding", "text":"Replacement", "if_empty":true}),
    );
    assert_eq!(retry["isError"], true, "{retry}");
    let linked = call("link_repo", json!({"path":repo, "link_agent_files":true}));
    assert_eq!(linked["isError"], false, "{linked}");
    assert!(
        fs::read_to_string(&agents)
            .unwrap()
            .starts_with("# Checkout rules\n\n<!-- secondbrain:begin -->")
    );
    let context = call("get_context", json!({"repo":"onboarding"}));
    assert!(
        context["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Verified checkout findings")
    );
}

#[test]
fn init_writes_gitattributes_once() {
    let root = temp("attrs").join("home");
    let home = Home { root };
    home.init().unwrap();
    let attrs = home.root.join(".gitattributes");
    assert_eq!(fs::read_to_string(&attrs).unwrap(), "* text eol=lf\n");
    fs::write(&attrs, "custom\n").unwrap();
    home.init().unwrap();
    assert_eq!(fs::read_to_string(&attrs).unwrap(), "custom\n");
}

#[test]
fn checkout_path_uses_one_separator() {
    let repo = git_repo("https://github.com/o/n.git");
    let (root, _) = secondbrain::ops::checkout(&repo).unwrap();
    if cfg!(windows) {
        assert!(!root.contains('/'), "{root}");
    }
    assert!(Path::new(&root).is_dir());
}

#[test]
fn guide_topics() {
    let home = temp("guide");
    assert!(sb(&home, &home, &["guide"]).contains("Topics"));
    assert!(sb(&home, &home, &["guide", "skills"]).contains("sb skill add"));
    assert!(sb(&home, &home, &["guide", "chat"]).contains("Refresh eligibility after each task"));
    assert!(sb(&home, &home, &["guide", "onboarding"]).contains("sb context --set --if-empty"));
    assert!(sb_err(&home, &home, &["guide", "nope"]).contains("unknown topic"));
}

#[test]
fn global_agent_file_alignment_uses_the_version_and_actual_block_content() {
    let home = temp("global-rules-home");
    let directory = temp("global-agent-profile");
    let file = directory.join("AGENTS.md");
    let backup = directory.join("AGENTS.md.sb-backup");
    let name = file.to_str().unwrap();
    sb(&home, &directory, &["init"]);
    fs::write(&file, "Personal instructions.\r\n").unwrap();
    let check = ["rules", "sync", "--check", "--agent-file", name];
    assert!(sb_err(&home, &directory, &check).contains("[unversioned]"));
    assert!(!backup.exists());
    sb(&home, &directory, &["rules", "sync", "--agent-file", name]);
    let aligned = fs::read_to_string(&file).unwrap();
    assert!(aligned.starts_with("Personal instructions.\r\n"));
    assert_eq!(
        fs::read_to_string(&backup).unwrap(),
        "Personal instructions.\r\n"
    );
    assert!(sb(&home, &directory, &check).contains("Aligned"));
    fs::write(&file, aligned.replace("Never copy dossier", "Copy dossier")).unwrap();
    assert!(sb_err(&home, &directory, &check).contains("Out of sync"));
    sb(&home, &directory, &["rules", "sync", "--agent-file", name]);
    assert_eq!(fs::read_to_string(&file).unwrap(), aligned);
}

#[test]
fn skills_and_repository_rules() {
    let home = temp("skillhome").join("h");
    let repo = git_repo("https://github.com/o/n.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);

    let skill = home.join("s.md");
    fs::write(
        &skill,
        "---\nname: tidy\ndescription: Tidies a diff\n---\nSteps\n",
    )
    .unwrap();
    assert!(
        sb(
            &home,
            &repo,
            &["skill", "add", "tidy", "--file", skill.to_str().unwrap()]
        )
        .contains("Added")
    );
    assert!(sb(&home, &repo, &["skill", "list"]).contains("tidy  Tidies a diff"));
    assert!(sb(&home, &repo, &["skill", "show", "tidy"]).contains("Steps"));
    assert!(
        run(
            Cli::parse_from([
                "sb",
                "--home",
                home.to_str().unwrap(),
                "skill",
                "show",
                "../x"
            ]),
            &repo
        )
        .is_err()
    );

    // Repository rules live in the dossier and reach the context, not the repository.
    let d = Home { root: home.clone() }
        .resolve_repo(None, &repo)
        .unwrap();
    d.set_rules("Always run the linter.").unwrap();
    let ctx = sb(&home, &repo, &["context"]);
    assert!(ctx.contains("## Repository rules") && ctx.contains("Always run the linter."));
    assert!(ctx.contains("- tidy: Tidies a diff"));
    assert!(sb(&home, &repo, &["rules", "show"]).contains("Always run the linter."));
    assert!(!repo.join("AGENTS.md").exists());

    sb(&home, &repo, &["skill", "remove", "tidy"]);
    assert!(sb(&home, &repo, &["skill", "list"]).contains("No skills"));
}

#[test]
fn start_screen_shows_the_checkout_alignment_and_next_steps() {
    let home = temp("start-home");
    let repo = git_repo("https://github.com/acme/start-demo.git");

    let before = sb(&home, &repo, &["start"]);
    assert!(before.contains("not set up"), "{before}");
    let (git_root, _) = secondbrain::ops::checkout(&repo).unwrap();
    assert!(
        before.contains(&format!("- Path        {git_root}")),
        "{before}"
    );
    assert!(
        before.contains("- GitHub      https://github.com/acme/start-demo"),
        "{before}"
    );
    assert!(before.contains("sb init"), "{before}");
    assert!(before.contains("Menus"), "{before}");

    sb(&home, &repo, &["init"]);
    let unlinked = sb(&home, &repo, &["start"]);
    assert!(unlinked.contains("none linked here"), "{unlinked}");
    assert!(unlinked.contains("sb add"), "{unlinked}");

    sb(&home, &repo, &["add", "--no-files"]);
    sb(&home, &repo, &["task", "add", "first"]);
    sb(
        &home,
        &repo,
        &["task", "add", "Second task", "--needs-user"],
    );
    sb(&home, &repo, &["check", "--install-hook"]);
    let screen = sb(&home, &repo, &["start"]);
    for needle in [
        "github.com/acme/start-demo (linked)",
        "Tasks: 2 open, 1 ready, 1 needs input",
        "- #1    ready",
        "- #2    needs input",
        "Quick start",
        "Run the next eligible task here",
        "sb task set 2 --needs-user false",
        "Prepare task #2 for unattended work",
        "sb run --task 1 --agent",
        "/blob/master/COMMANDS.md",
        "Alignment (local)",
        "checkout recorded in the dossier",
        "no managed AGENTS.md block",
        "SecondBrain hook installed",
        "- MCP ",
        "- Health ",
        "sb task prepare 2",
        "sb run --dry-run",
        "Menus",
        "sb commands",
    ] {
        assert!(
            screen.contains(needle),
            "missing `{needle}`:
{screen}"
        );
    }
    assert!(
        screen.lines().count() < 70,
        "the dashboard stays compact:
{screen}"
    );
    assert_eq!(
        sb(&home, &repo, &[]),
        screen,
        "bare `sb` shows the same screen"
    );
}

#[test]
fn start_repairs_managed_agent_files_and_explains_remaining_findings() {
    let home = temp("start-alignment");
    let repo = git_repo("https://example.invalid/fixtures/start-alignment.git");
    let profile = temp("start-alignment-codex");
    sb(&home, &repo, &["init"]);
    let agents = repo.join("AGENTS.md");
    fs::write(&agents, "# My repository\n\nKeep this text.\n").unwrap();
    sb(&home, &repo, &["add"]);
    fs::write(home.join("rules.md"), "Updated fixture rules.\n").unwrap();
    assert!(sb(&home, &repo, &["start", "setup"]).contains("sb start setup"));
    assert!(
        !fs::read_to_string(&agents)
            .unwrap()
            .contains("Updated fixture rules.")
    );
    let claude = repo.join("CLAUDE.md");
    fs::remove_file(&claude).unwrap();
    let gemini = repo.join("GEMINI.md");
    fs::write(&gemini, "# Custom instructions\n").unwrap();
    let missing = serde_json::to_string(&profile.join("missing-sb")).unwrap();
    let config = format!("[mcp_servers.secondbrain]\ncommand = {missing}\nargs = [\"mcp\"]\n");
    fs::write(profile.join("config.toml"), &config).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&repo)
        .envs([
            ("HOME", &profile),
            ("USERPROFILE", &profile),
            ("APPDATA", &profile),
            ("LOCALAPPDATA", &profile),
            ("XDG_CONFIG_HOME", &profile),
            ("GEMINI_CLI_HOME", &profile),
        ])
        .env("CODEX_HOME", &profile)
        .env("CLAUDE_DESKTOP_CONFIG_DIR", profile.join("empty-claude"))
        .env("COPILOT_HOME", profile.join("empty-copilot"))
        .arg("--home")
        .arg(&home)
        .arg("start")
        .output()
        .unwrap();
    assert!(output.status.success());
    let screen = String::from_utf8(output.stdout).unwrap();
    assert!(
        screen.contains("- Agent files 1 finding to review") && screen.contains("2 repaired"),
        "{screen}"
    );
    assert!(
        screen.contains("Codex")
            && screen.contains("finding")
            && screen.contains("[configuration]"),
        "{screen}"
    );
    assert!(!screen.contains("- GitHub "), "{screen}");
    assert!(screen.contains("sb mcp install --client codex"), "{screen}");
    assert!(screen.contains("add a line `@AGENTS.md`"), "{screen}");
    assert!(
        screen.contains("sb doctor") && screen.contains("Review local alignment findings"),
        "{screen}"
    );
    let updated = fs::read_to_string(&agents).unwrap();
    assert!(updated.starts_with("# My repository\n\nKeep this text.\n"));
    assert!(updated.contains("Updated fixture rules."));
    assert_eq!(fs::read_to_string(&claude).unwrap(), "@AGENTS.md\n");
    assert_eq!(
        fs::read_to_string(&gemini).unwrap(),
        "# Custom instructions\n"
    );
    assert_eq!(
        fs::read_to_string(profile.join("config.toml")).unwrap(),
        config
    );
    assert!(!sb(&home, &repo, &["start"]).contains("2 repaired"));

    let broken = "<!-- secondbrain:begin -->\nUnfinished block\n";
    fs::write(&agents, broken).unwrap();
    assert!(sb(&home, &repo, &["start"]).contains("restore one complete managed block"));
    assert_eq!(fs::read_to_string(&agents).unwrap(), broken);

    sb(&home, &repo, &["unlink"]);
    fs::write(&agents, updated).unwrap();
    fs::remove_file(&gemini).unwrap();
    fs::write(home.join("rules.md"), "A different fixture rule.\n").unwrap();
    let unrecorded = sb(&home, &repo, &["start"]);
    assert!(
        unrecorded.contains("checkout path not recorded"),
        "{unrecorded}"
    );
    assert!(unrecorded.contains("sb add"), "{unrecorded}");
    assert!(
        fs::read_to_string(&agents)
            .unwrap()
            .contains("Updated fixture rules.")
    );
    assert!(!claude.exists());
}

#[test]
fn start_menus_work_without_a_linked_repository_or_initialized_home() {
    let directory = temp("start-menu");
    let home = directory.join("missing-home");
    let dashboard = sb(&home, &directory, &[]);
    assert_eq!(dashboard, sb(&home, &directory, &["start"]));
    assert!(
        dashboard
            .contains("commands and parameter descriptions in bullet lists in the first reply")
    );
    assert!(dashboard.contains("sb guide onboarding"));
    assert!(
        sb(&home, &directory, &["start", "work", "run"])
            .contains("--limit <LIMIT>  Run at most this many tasks")
    );
    for area in ["setup", "work", "rules", "publish", "help"] {
        assert!(dashboard.contains(&format!("sb start {area}")));
        let menu = sb(&home, &directory, &["start", area]);
        assert!(menu.contains(&format!("Details: sb start {area} <command>")));
        assert!(menu.contains("Back: sb start"));
    }
    let tasks = sb(&home, &directory, &["start", "work", "task"]);
    assert!(tasks.contains("sb task add       Create a task"));
    assert!(tasks.contains("sb start work task <subcommand>"));
    let add = sb(&home, &directory, &["start", "work", "task", "add"]);
    assert!(add.contains("Usage: sb task add --help"));
    assert!(add.contains("Back: sb start work task"));
    assert!(add.contains("--body <BODY>  Task scope, inputs and acceptance criteria"));
    assert!(add.contains("--repo <REPO>  Repository (identity, its last part, or a folder"));
    let mcp = sb(&home, &directory, &["start", "publish", "mcp"]);
    assert!(mcp.contains("sb mcp install"));
    assert!(sb_err(&home, &directory, &["start", "rules", "task"]).contains("sb start rules"));
    assert!(
        sb_err(&home, &directory, &["start", "work", "task", "missing"])
            .contains("sb start work task")
    );
    assert!(!home.exists());
}

#[test]
fn prepare_interview_can_cancel_hold_and_make_a_task_eligible() {
    use std::io::Write;
    use std::process::Stdio;

    let home = temp("prepare-home");
    let repo = git_repo("https://example.invalid/fixtures/prepare.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(&home, &repo, &["task", "add", "Prerequisite"]);
    sb(
        &home,
        &repo,
        &[
            "task",
            "add",
            "Prepare fixture",
            "--needs-user",
            "--blocked-by",
            "1",
            "--body",
            "Keep the original description.",
            "--accept",
            "cargo check",
        ],
    );
    let dossier = Home { root: home.clone() }
        .resolve_repo(None, &repo)
        .unwrap();
    let original = dossier.task(2).unwrap();
    let interview = |answers: &str| {
        let mut child = Command::new(env!("CARGO_BIN_EXE_sb"))
            .current_dir(&repo)
            .arg("--home")
            .arg(&home)
            .args(["task", "prepare", "2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(answers.as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
    };

    assert!(!interview("src\n").status.success());
    assert_eq!(dossier.task(2).unwrap(), original);
    assert!(
        interview("src\nExpected result\n\n\n\n\n\n\ncancel\n")
            .status
            .success()
    );
    assert_eq!(dossier.task(2).unwrap(), original);

    let hold = interview(
        "src\nExpected result\nUnit tests\n\n\nInput missing\nUse fixture data\nPush needs approval\nhold\n",
    );
    assert!(
        hold.status.success(),
        "{}",
        String::from_utf8_lossy(&hold.stderr)
    );
    let task = dossier.task(2).unwrap();
    assert!(task.needs_user && task.body.contains("Input missing"));
    assert!(
        task.body
            .contains("**Authorizations**\nPush needs approval")
    );
    assert!(task.body.contains("Keep the original description."));
    assert_eq!(task.accept.as_deref(), Some("cargo check"));

    let ready = interview(
        "src\nExpected result\nUnit tests\ncargo test\ncargo, npm\nInput provided\nUse fixture data\nNo approvals needed\nready\n",
    );
    assert!(
        ready.status.success(),
        "{}",
        String::from_utf8_lossy(&ready.stderr)
    );
    let task = dossier.task(2).unwrap();
    assert!(!task.needs_user);
    assert_eq!(task.accept.as_deref(), Some("cargo test"));
    assert_eq!(task.blocked_by, [1]);
    assert_eq!(task.body.matches("## Unattended handoff").count(), 1);
    assert!(!task.body.contains("Input missing"));
    assert!(task.body.contains("Input provided"));
    assert!(task.body.contains("**Commands**\ncargo, npm"));
    assert!(!sb(&home, &repo, &["task", "ready"]).contains("Prepare fixture"));
    sb(&home, &repo, &["task", "done", "1"]);
    assert!(sb(&home, &repo, &["run", "--task", "2", "--dry-run"]).contains("Prepare fixture"));
}

#[test]
fn start_checks_current_tasks_without_scanning_other_task_files_or_the_index() {
    let home = temp("start-health");
    let current = git_repo("https://example.invalid/fixtures/current.git");
    let other = git_repo("https://example.invalid/fixtures/other.git");
    sb(&home, &current, &["init"]);
    for checkout in [&current, &other] {
        sb(&home, checkout, &["add", "--no-files"]);
        sb(&home, checkout, &["task", "add", "Fixture task"]);
    }
    let health = || {
        sb(&home, &current, &["start"])
            .lines()
            .find(|line| line.starts_with("- Health "))
            .unwrap()
            .to_string()
    };
    let baseline = health();
    let data = Home { root: home.clone() };
    let write_broken_task = |checkout: &Path| {
        let dossier = data.resolve_repo(None, checkout).unwrap();
        let file = dossier.task_files().unwrap().remove(0).0;
        fs::write(&file, "Invalid fixture task").unwrap();
        file
    };
    write_broken_task(&other);
    let index = secondbrain::index::path(&data);
    let original = b"Invalid fixture index";
    fs::write(&index, original).unwrap();
    assert_eq!(health(), baseline);
    assert_eq!(fs::read(index).unwrap(), original);

    let broken = write_broken_task(&current);
    assert_ne!(health(), baseline);
    assert_eq!(fs::read_to_string(broken).unwrap(), "Invalid fixture task");
}

#[test]
fn start_repairs_other_recorded_checkouts_and_skips_changed_identities() {
    let home = temp("managed-home");
    let elsewhere = temp("managed-elsewhere");
    let current = git_repo("https://example.invalid/fixtures/current.git");
    let other = git_repo("https://example.invalid/fixtures/other.git");
    let clone = git_repo("https://example.invalid/fixtures/other.git");
    let changed = git_repo("https://example.invalid/fixtures/changed.git");
    sb(&home, &current, &["init"]);
    for root in [&current, &other, &clone, &changed] {
        sb(&home, root, &["add"]);
    }
    fs::write(
        other.join("AGENTS.md"),
        "# Own rules\n\n<!-- secondbrain:begin -->\n## SecondBrain\nOld instructions.\n<!-- secondbrain:end -->\n",
    )
    .unwrap();
    let git = Command::new("git")
        .current_dir(&changed)
        .args([
            "remote",
            "set-url",
            "origin",
            "https://example.invalid/fixtures/replaced.git",
        ])
        .status()
        .unwrap();
    assert!(git.success());
    let broken = home.join("repos/broken-dossier");
    fs::create_dir_all(&broken).unwrap();
    fs::write(broken.join("repo.json"), "invalid JSON").unwrap();
    fs::write(home.join("rules.md"), "Fixture alignment rule.\n").unwrap();
    let screen = sb(&home, &elsewhere, &["start"]);
    assert!(screen.contains("3 checkouts checked"), "{screen}");
    assert!(screen.contains("3 repaired"), "{screen}");
    assert!(screen.contains("Git identity changed"), "{screen}");
    assert!(screen.contains("broken-dossier"), "{screen}");
    let refreshed = fs::read_to_string(other.join("AGENTS.md")).unwrap();
    assert!(refreshed.starts_with("# Own rules\n\n<!-- secondbrain:begin -->"));
    assert!(refreshed.contains("include the full result in the first reply after execution"));
    for root in [&current, &other, &clone] {
        assert!(
            fs::read_to_string(root.join("AGENTS.md"))
                .unwrap()
                .contains("Fixture alignment rule.")
        );
    }
    assert!(
        !fs::read_to_string(changed.join("AGENTS.md"))
            .unwrap()
            .contains("Fixture alignment rule.")
    );
}

#[test]
fn start_finds_a_newer_build_behind_an_unmarked_path_entry_without_running_it() {
    let home = temp("executable-home");
    let repo = git_repo("https://example.invalid/fixtures/executable.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add"]);
    fs::write(home.join("rules.md"), "Fixture executable rule.\n").unwrap();
    let shadow = temp("executable-shadow");
    let alternate = temp("executable-alternate");
    let filename = format!("sb{}", std::env::consts::EXE_SUFFIX);
    let stale = shadow.join(&filename);
    let newer = alternate.join(&filename);
    fs::write(&stale, "unmarked fixture").unwrap();
    fs::write(
        &newer,
        format!(
            "fixture SB_BUILD_V1|{}|99999999999999999999|feedfeedfeedfeed|END_SB_BUILD",
            env!("CARGO_PKG_VERSION")
        ),
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for path in [&stale, &newer] {
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
    let path = std::env::var_os("PATH").unwrap();
    let search = std::env::join_paths(
        [shadow, alternate]
            .into_iter()
            .chain(std::env::split_paths(&path)),
    )
    .unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&repo)
        .env("PATH", search)
        .args(["--home", home.to_str().unwrap(), "start"])
        .output()
        .unwrap();
    assert!(result.status.success());
    let screen = String::from_utf8(result.stdout).unwrap();
    assert!(
        screen.contains(&format!(
            "- PATH        {} [no SecondBrain build marker]",
            stale.display()
        )),
        "{screen}"
    );
    assert!(
        screen.contains(&format!("- Newer build  {}", newer.display())),
        "{screen}"
    );
    assert!(
        screen.contains("Managed file repairs are paused"),
        "{screen}"
    );
    assert!(
        !fs::read_to_string(repo.join("AGENTS.md"))
            .unwrap()
            .contains("Fixture executable rule.")
    );
}

#[test]
fn commands_lists_every_command() {
    use clap::CommandFactory;
    let home = temp("commands-home");
    let repo = git_repo("https://github.com/acme/commands-demo.git");
    let screen = sb(&home, &repo, &["commands"]);
    assert_eq!(sb(&home, &repo, &["guide", "commands"]), screen);
    let response = mcp::handle(
        &Home { root: home.clone() },
        &repo,
        &json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "get_guide", "arguments": { "topic": "commands" } }
        }),
    )
    .unwrap();
    assert_eq!(
        response["result"]["content"][0]["text"].as_str(),
        Some(screen.as_str())
    );
    for c in Cli::command().get_subcommands() {
        if c.is_hide_set() || c.get_name() == "help" {
            continue;
        }
        let line = format!("sb {:<9} ", c.get_name());
        assert!(
            screen.contains(&line),
            "`sb commands` misses `{}`",
            c.get_name()
        );
    }
    for switch in [
        "--set",
        "--fix",
        "--budget <TOKENS>",
        "sb task add  Create a task",
        "<TITLE>  Short task title (required)",
    ] {
        assert!(
            screen.contains(switch),
            "`sb commands` misses `{switch}`:\n{screen}"
        );
    }
    for line in screen.lines().filter(|line| line.starts_with(' ')) {
        let (_, example) = line
            .split_once("  Example: ")
            .unwrap_or_else(|| panic!("Missing example: {line}"));
        let invocation = example
            .rsplit_once(" | ")
            .map_or(example, |(_, command)| command);
        let mut args = Vec::new();
        for (index, segment) in invocation.split('"').enumerate() {
            if index % 2 == 0 {
                args.extend(segment.split_whitespace());
            } else {
                args.push(segment);
            }
        }
        if let Err(error) = Cli::try_parse_from(args) {
            assert!(
                matches!(
                    error.kind(),
                    clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion
                ),
                "{example}: {error}"
            );
        }
    }
}

#[test]
fn task_graph_ready_claim_and_release() {
    let home = temp("graph-home");
    let repo = git_repo("https://github.com/acme/graph-demo.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(&home, &repo, &["task", "add", "base", "-p", "2"]);
    sb(&home, &repo, &["task", "add", "next", "--blocked-by", "1"]);
    sb(&home, &repo, &["task", "add", "human", "--needs-user"]);

    let ready = sb(&home, &repo, &["task", "ready"]);
    assert!(ready.contains("#1 [todo]") && !ready.contains("next") && !ready.contains("human"));
    let list = sb(&home, &repo, &["task", "list"]);
    assert!(list.contains("(waits for #1)"), "{list}");

    // A loop and a missing blocker are refused.
    let err = sb_err(&home, &repo, &["task", "set", "1", "--blocked-by", "2"]);
    assert!(err.contains("cycle"), "{err}");
    let err = sb_err(&home, &repo, &["task", "set", "2", "--blocked-by", "99"]);
    assert!(err.contains("no task #99"), "{err}");
    let err = sb_err(&home, &repo, &["task", "claim", "2", "--by", "a"]);
    assert!(err.contains("not ready"), "{err}");

    // One claimer wins; the task is held until released.
    sb(&home, &repo, &["task", "claim", "1", "--by", "agent-a"]);
    let err = sb_err(&home, &repo, &["task", "claim", "1", "--by", "agent-b"]);
    assert!(
        err.contains("not ready") && err.contains("agent-a"),
        "{err}"
    );
    assert!(sb(&home, &repo, &["task", "ready"]).contains("No tasks"));
    sb(&home, &repo, &["task", "release", "1"]);
    assert!(sb(&home, &repo, &["task", "ready"]).contains("#1"));

    // Finishing the blocker frees the next task.
    sb(&home, &repo, &["task", "done", "1"]);
    let ready = sb(&home, &repo, &["task", "ready"]);
    assert!(
        ready.contains("#2") && !ready.contains("waits for"),
        "{ready}"
    );
}

#[test]
fn concurrent_writers_get_distinct_ids_and_one_claim() {
    use std::sync::Arc;
    let home_dir = temp("conc-home");
    let home = Home::resolve(Some(&home_dir)).unwrap();
    home.init().unwrap();
    let (d, _) = home.find_or_create("example.invalid/acme/conc").unwrap();
    let d = Arc::new(d);

    let handles: Vec<_> = (0..8)
        .map(|i| {
            let d = Arc::clone(&d);
            std::thread::spawn(move || {
                d.add_task(&format!("task {i}"), "", None, false)
                    .unwrap()
                    .id
            })
        })
        .collect();
    let mut ids: Vec<u32> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    ids.sort_unstable();
    assert_eq!(ids, (1..=8).collect::<Vec<u32>>());

    let claims: Vec<_> = (0..6)
        .map(|i| {
            let d = Arc::clone(&d);
            std::thread::spawn(move || d.claim_task(1, &format!("agent-{i}"), 5).is_ok())
        })
        .collect();
    let won = claims
        .into_iter()
        .filter(|_| true)
        .map(|h| h.join().unwrap())
        .filter(|ok| *ok)
        .count();
    assert_eq!(won, 1, "exactly one claimer gets the task");
}

#[test]
fn search_is_ranked_survives_edits_and_a_deleted_index() {
    let home = temp("fts-home");
    let repo = git_repo("https://github.com/acme/fts-demo.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(
        &home,
        &repo,
        &[
            "task",
            "add",
            "Fix the login redirect",
            "--body",
            "OAuth callback loops",
        ],
    );
    sb(&home, &repo, &["task", "add", "Write docs"]);
    sb(&home, &repo, &["decide", "Use sessions for login — simple"]);

    let hits = sb(&home, &repo, &["search", "login"]);
    assert!(
        hits.contains("Fix the login redirect") && hits.contains("decision"),
        "{hits}"
    );
    assert!(!hits.contains("Write docs"));
    // Prefixes and several words work; FTS syntax in the text does not break it.
    assert!(sb(&home, &repo, &["search", "redir"]).contains("login redirect"));
    assert!(sb(&home, &repo, &["search", "oauth loops"]).contains("login redirect"));
    assert!(sb(&home, &repo, &["search", "\"login\" OR (x"]).contains("login"));
    assert!(sb(&home, &repo, &["search", "zzzz"]).contains("Nothing found"));

    // The index follows edits and is rebuilt when it is deleted.
    sb(
        &home,
        &repo,
        &["task", "set", "2", "--title", "Write the changelog"],
    );
    assert!(sb(&home, &repo, &["search", "changelog"]).contains("#2"));
    assert!(home.join("index.db").is_file());
    fs::remove_file(home.join("index.db")).unwrap();
    assert!(sb(&home, &repo, &["search", "changelog"]).contains("#2"));

    // A damaged index is repaired by doctor or on the next search.
    fs::write(home.join("index.db"), b"not a database").unwrap();
    assert!(sb(&home, &repo, &["search", "changelog"]).contains("#2"));
}

#[test]
fn context_budget_trims_tasks_and_decisions_but_not_the_state() {
    let home = temp("budget-home");
    let repo = git_repo("https://github.com/acme/budget-demo.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    for i in 1..=25 {
        sb(
            &home,
            &repo,
            &[
                "task",
                "add",
                &format!("Task number {i} with a fairly long title for the list"),
                "-p",
                &(1 + i % 4).to_string(),
            ],
        );
    }
    for i in 1..=10 {
        sb(
            &home,
            &repo,
            &[
                "decide",
                &format!("Decision {i} — {}", "reason ".repeat(40)),
            ],
        );
    }
    let state = "The current state must always be complete.";
    let (d, _) = Home::resolve(Some(&home))
        .unwrap()
        .find_or_create("github.com/acme/budget-demo")
        .unwrap();
    d.set_context(state).unwrap();

    let full = sb(&home, &repo, &["context"]);
    let small = sb(&home, &repo, &["context", "--budget", "400"]);
    assert!(small.contains(state) && full.contains(state));
    assert!(
        small.len() < full.len() / 2,
        "{} vs {}",
        small.len(),
        full.len()
    );
    assert!(
        small.chars().count().div_ceil(4) <= 520,
        "stays near the budget: {}",
        small.len()
    );
    assert!(
        small.contains("more: `sb task list`") && small.contains("older: `sb search"),
        "{small}"
    );
    // Highest priority first, newest decision kept.
    assert!(small.contains("Decision 10") && !small.contains("Decision 1 "));
    // --budget 0 means no limit; a huge budget changes nothing.
    assert_eq!(sb(&home, &repo, &["context", "--budget", "0"]), full);
    assert_eq!(sb(&home, &repo, &["context", "--budget", "100000"]), full);
}

#[test]
fn context_compact_trims_a_large_state_by_section_and_doctor_warns() {
    let home = temp("compact-home");
    let repo = git_repo("https://github.com/acme/compact-demo.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    let filler = "background words ".repeat(300);
    let state = format!(
        "Intro line.\n\n## Current state\n\nKeep this section.\n\n## History\n\n{filler}\n\n## Archive notes\n\n{filler}\n"
    );
    let (d, _) = Home::resolve(Some(&home))
        .unwrap()
        .find_or_create("github.com/acme/compact-demo")
        .unwrap();
    d.set_context(&state).unwrap();

    let compact = sb(&home, &repo, &["context", "--compact"]);
    assert!(compact.contains("Intro line.") && compact.contains("Keep this section."));
    assert!(!compact.contains("background words"), "{compact}");
    assert!(
        compact.contains("2 sections omitted: History, Archive notes"),
        "{compact}"
    );
    let small = sb(&home, &repo, &["context", "--budget", "400"]);
    assert!(small.contains("sections omitted") && !small.contains("background words"));
    // Without a budget (or with 0) the state is complete.
    for args in [&["context"][..], &["context", "--budget", "0"][..]] {
        let full = sb(&home, &repo, args);
        assert!(full.contains(&filler) && !full.contains("sections omitted"));
    }

    let big = format!("{state}\n## More\n\n{}\n", "padding words ".repeat(1000));
    d.set_context(&big).unwrap();
    assert!(sb_err(&home, &repo, &["doctor"]).contains("context.md is about"));
}

fn git_in(dir: &Path, args: &[&str]) -> String {
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

fn j(parts: &[&str]) -> String {
    parts.concat()
}

#[test]
fn sync_moves_the_dossier_between_machines_and_stops_on_secrets() {
    let remote = temp("sync-remote");
    git_in(&remote, &["init", "-q", "--bare", "-b", "main"]);
    let url = remote.to_str().unwrap().to_string();
    let repo = git_repo("https://github.com/acme/sync-demo.git");

    // Machine A creates data and syncs.
    let a = temp("sync-a");
    sb(&a, &repo, &["init"]);
    git_in(&a, &["checkout", "-q", "-B", "main"]);
    sb(&a, &repo, &["add", "--no-files"]);
    sb(&a, &repo, &["task", "add", "from machine A"]);
    sb(&a, &repo, &["search", "machine"]); // creates index.db, which must stay local
    let note = a.join("note.md");
    fs::write(&note, "Local only note about machine A").unwrap();
    sb(
        &a,
        &repo,
        &[
            "kb",
            "add",
            "Local note",
            "--text-file",
            note.to_str().unwrap(),
        ],
    );
    let out = sb(&a, &repo, &["sync", "--remote", &url]);
    assert!(out.contains("Pushed"), "{out}");
    let tracked = git_in(&a, &["ls-files"]);
    assert!(
        !tracked.contains("index.db")
            && !tracked.contains("kb.db")
            && tracked.contains("from-machine-a"),
        "{tracked}"
    );

    // Machine B starts empty, adopts the remote, adds a task and syncs back.
    let b = temp("sync-b");
    sb(&b, &repo, &["init"]);
    git_in(&b, &["checkout", "-q", "-B", "main"]);
    let out = sb(&b, &repo, &["sync", "--remote", &url]);
    assert!(out.contains("Adopted"), "{out}");
    sb(&b, &repo, &["task", "add", "from machine B"]);
    sb(&b, &repo, &["sync"]);

    // A pulls B's task.
    sb(&a, &repo, &["sync"]);
    let list = sb(&a, &repo, &["task", "list"]);
    assert!(
        list.contains("from machine A") && list.contains("from machine B"),
        "{list}"
    );
    assert!(sb(&a, &repo, &["sync"]).contains("already has everything"));

    // A secret stops the sync before anything is committed or pushed.
    let secret = j(&["ghp_", &"a1B2c3D4e5F6g7H8i9J0".repeat(2)]);
    sb(&a, &repo, &["decide", &format!("token is {secret}")]);
    let before = git_in(&remote, &["rev-parse", "main"]);
    let err = sb_err(&a, &repo, &["sync"]);
    assert!(
        err.contains("finding") || err.contains("decisions.md"),
        "{err}"
    );
    assert_eq!(
        git_in(&remote, &["rev-parse", "main"]),
        before,
        "nothing was pushed"
    );
}

#[test]
fn sync_preserves_custom_rules_when_the_first_remote_already_has_data() {
    let remote = temp("custom-rules-remote");
    git_in(&remote, &["init", "-q", "--bare", "-b", "main"]);
    let source = temp("custom-rules-source");
    let fresh = temp("custom-rules-local");
    sb(&source, &source, &["init"]);
    git_in(&source, &["checkout", "-q", "-B", "main"]);
    sb(
        &source,
        &source,
        &["sync", "--remote", remote.to_str().unwrap()],
    );
    sb(&fresh, &fresh, &["init"]);
    fs::write(fresh.join("rules.md"), b"A custom local rule.\n").unwrap();
    assert!(
        sb_err(
            &fresh,
            &fresh,
            &["sync", "--remote", remote.to_str().unwrap()]
        )
        .contains("share no history")
    );
    assert_eq!(
        fs::read(fresh.join("rules.md")).unwrap(),
        b"A custom local rule.\n"
    );
    assert!(!fresh.join("repos").read_dir().unwrap().any(|_| true));
}

#[test]
fn sync_keeps_same_number_same_title_tasks_and_their_original_dependencies() {
    let remote = temp("task-keys-remote");
    git_in(&remote, &["init", "-q", "--bare", "-b", "main"]);
    let url = remote.to_str().unwrap();
    let repo = git_repo("https://example.invalid/fixtures/task-keys.git");
    let a = temp("task-keys-a");
    let b = temp("task-keys-b");
    sb(&a, &repo, &["init"]);
    git_in(&a, &["checkout", "-q", "-B", "main"]);
    sb(&a, &repo, &["add", "--no-files"]);
    sb(&a, &repo, &["sync", "--remote", url]);
    sb(&b, &repo, &["init"]);
    git_in(&b, &["checkout", "-q", "-B", "main"]);
    sb(&b, &repo, &["sync", "--remote", url]);
    for (home, blocker, dependent) in [
        (&a, "A blocker", "A dependent"),
        (&b, "B blocker", "B dependent"),
    ] {
        sb(
            home,
            &repo,
            &["task", "add", "Same title", "--body", blocker],
        );
        sb(
            home,
            &repo,
            &[
                "task",
                "add",
                "Same title",
                "--body",
                dependent,
                "--blocked-by",
                "1",
            ],
        );
    }
    sb(&a, &repo, &["task", "done", "1"]);
    sb(&a, &repo, &["sync"]);
    let global_config = temp("task-keys-config").join("gitconfig");
    fs::write(&global_config, "").unwrap();
    // A fresh machine may have no Git identity, even when this test runner has one.
    let output = Command::new(env!("CARGO_BIN_EXE_sb"))
        .current_dir(&repo)
        .env("GIT_CONFIG_GLOBAL", global_config)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "user.useConfigOnly")
        .env("GIT_CONFIG_VALUE_0", "true")
        .env_remove("GIT_CONFIG_PARAMETERS")
        .env_remove("GIT_AUTHOR_NAME")
        .env_remove("GIT_AUTHOR_EMAIL")
        .env_remove("GIT_COMMITTER_NAME")
        .env_remove("GIT_COMMITTER_EMAIL")
        .arg("--home")
        .arg(&b)
        .arg("sync")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let merged = String::from_utf8(output.stdout).unwrap();
    assert!(merged.contains("Reassigned 2"), "{merged}");
    sb(&a, &repo, &["sync"]);
    for home in [a, b] {
        let d = Home { root: home }.resolve_repo(None, &repo).unwrap();
        let tasks = d.tasks().unwrap();
        for (blocker, dependent) in [("A blocker", "A dependent"), ("B blocker", "B dependent")] {
            let original = tasks.iter().find(|task| task.body == blocker).unwrap();
            assert_eq!(
                tasks
                    .iter()
                    .find(|task| task.body == dependent)
                    .unwrap()
                    .blocked_by,
                [original.id]
            );
        }
        let ready = d.ready_tasks().unwrap();
        assert!(ready.iter().any(|task| task.body == "A dependent"));
        assert!(!ready.iter().any(|task| task.body == "B dependent"));
    }
}

#[test]
fn local_repositories_with_the_same_name_keep_distinct_dossiers_and_legacy_access() {
    let home = Home {
        root: temp("local-identities-home"),
    };
    home.init().unwrap();
    let a = temp("local-identities-a").join("same-name");
    let b = temp("local-identities-b").join("same-name");
    for path in [&a, &b] {
        fs::create_dir(path).unwrap();
        git_in(path, &["init", "-q"]);
    }
    let mut legacy = home.create("local/same-name").unwrap();
    legacy.add_path(a.to_str().unwrap());
    legacy.save_meta().unwrap();
    legacy.add_task("Legacy task", "", None, false).unwrap();
    sb(&home.root, &b, &["add", "--no-files"]);
    let b_dossier = home.resolve_repo(None, &b).unwrap();
    assert_ne!(legacy.dir, b_dossier.dir);
    assert!(b_dossier.tasks().unwrap().is_empty());
    assert_eq!(
        home.resolve_repo(None, &a).unwrap().task(1).unwrap().title,
        "Legacy task"
    );
}

#[test]
fn concurrent_decisions_preserve_every_append_and_fail_on_unreadable_data() {
    let home = Home {
        root: temp("decisions-home"),
    };
    home.init().unwrap();
    let d = home.create("local/concurrent-decisions").unwrap();
    std::thread::scope(|scope| {
        for i in 0..12 {
            let d = &d;
            scope.spawn(move || {
                d.add_decision(&format!("Fixture decision {i}")).unwrap();
            });
        }
    });
    assert_eq!(d.decisions().unwrap().len(), 12);
    let file = d.dir.join("decisions.md");
    fs::write(&file, [0xff]).unwrap();
    assert!(d.add_decision("Further decision").is_err());
    assert_eq!(fs::read(file).unwrap(), [0xff]);
}

#[test]
fn concurrent_migration_and_task_add_allocate_fresh_numbers_under_one_lock() {
    let home = Home {
        root: temp("migration-lock-home"),
    };
    home.init().unwrap();
    let d = home
        .create("example.invalid/fixtures/migration-lock")
        .unwrap();
    let export = temp("migration-lock-export").join("export.json");
    let tasks: Vec<_> = (0..8)
        .map(|i| json!({"id": format!("legacy-{i}"), "title": format!("Migrated {i}")}))
        .collect();
    fs::write(&export, json!({"repositories":[{"identity":"example.invalid/fixtures/migration-lock", "tasks":tasks}]}).to_string()).unwrap();
    std::thread::scope(|scope| {
        for _ in 0..2 {
            scope.spawn(|| secondbrain::migrate::run(&home, &export, false).unwrap());
        }
        for i in 0..8 {
            let d = &d;
            scope.spawn(move || d.add_task(&format!("New {i}"), "", None, false).unwrap());
        }
    });
    let tasks = d.tasks().unwrap();
    assert_eq!(tasks.len(), 16);
    assert_eq!(
        tasks.iter().filter(|task| task.legacy_id.is_some()).count(),
        8
    );
    assert_eq!(
        tasks.iter().map(|task| task.id).collect::<Vec<_>>(),
        (1..=16).collect::<Vec<_>>()
    );
}

#[test]
fn import_reads_instruction_files_once_and_export_writes_plain_formats() {
    let home = temp("port-home");
    let repo = git_repo("https://github.com/acme/port-demo.git");
    sb(&home, &repo, &["init"]);
    // Nothing to import before the repository is added.
    assert!(sb_err(&home, &repo, &["import"]).contains("sb add"));
    sb(&home, &repo, &["add", "--no-files"]);

    fs::write(repo.join("AGENTS.md"), "# Repo\n\nRun cargo fmt before a commit.\n\n<!-- secondbrain:begin -->\n## SecondBrain\nblock text\n<!-- secondbrain:end -->\n").unwrap();
    fs::write(repo.join("CLAUDE.md"), "@AGENTS.md\n").unwrap();
    fs::create_dir_all(repo.join(".cursor").join("rules")).unwrap();
    fs::write(
        repo.join(".cursor").join("rules").join("style.mdc"),
        "---\nalwaysApply: true\n---\nUse four spaces.\n",
    )
    .unwrap();
    let key = j(&["ghp_", &"a1B2c3D4e5F6g7H8i9J0".repeat(2)]);
    fs::write(repo.join("GEMINI.md"), format!("Token {key} is the key.\n")).unwrap();
    let before = fs::read_to_string(repo.join("AGENTS.md")).unwrap();

    let plan = sb(&home, &repo, &["import", "--dry-run"]);
    assert!(
        plan.contains("AGENTS.md: 3 line(s) would be imported"),
        "{plan}"
    );
    assert!(
        sb(&home, &repo, &["rules", "show"]).contains("(none")
            || !sb(&home, &repo, &["rules", "show"]).contains("cargo fmt")
    );

    let out = sb(&home, &repo, &["import"]);
    assert!(out.contains("CLAUDE.md: nothing to import"), "{out}");
    assert!(out.contains("GEMINI.md: skipped"), "{out}");
    assert!(
        out.contains("style.mdc") && out.contains("imported"),
        "{out}"
    );
    let rules = sb(&home, &repo, &["rules", "show"]);
    assert!(rules.contains("Run cargo fmt before a commit.") && rules.contains("Use four spaces."));
    assert!(!rules.contains("block text") && !rules.contains("ghp_"));
    assert_eq!(
        fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
        before,
        "the repository is untouched"
    );

    // A second import adds nothing.
    let again = sb(&home, &repo, &["import"]);
    assert!(
        again.contains("already in the rules") && !again.contains("Added to the rules"),
        "{again}"
    );

    // Export: Markdown and JSON, to stdout and to a file outside any repository.
    sb(
        &home,
        &repo,
        &["task", "add", "exported task", "--body", "details"],
    );
    let md = sb(&home, &repo, &["export"]);
    assert!(
        md.contains("## Rules") && md.contains("exported task") && md.contains("Use four spaces."),
        "{md}"
    );
    let json = sb(&home, &repo, &["export", "--format", "json"]);
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["identity"], "github.com/acme/port-demo");
    assert_eq!(v["tasks"][0]["title"], "exported task");
    let target = temp("port-out").join("dossier.json");
    assert!(
        sb(
            &home,
            &repo,
            &[
                "export",
                "--format",
                "json",
                "--out",
                target.to_str().unwrap()
            ]
        )
        .contains("Wrote")
    );
    assert!(
        fs::read_to_string(&target)
            .unwrap()
            .contains("exported task")
    );
    let inside = repo.join("dossier.md");
    let err = sb_err(&home, &repo, &["export", "--out", inside.to_str().unwrap()]);
    assert!(err.contains("inside a Git repository"), "{err}");
    assert!(!inside.exists());
    assert!(sb_err(&home, &repo, &["export", "--format", "xml"]).contains("unknown format"));
}

#[test]
fn distinct_repository_identities_do_not_share_legacy_dossiers() {
    let home_path = temp("isolated-dossiers");
    let first = git_repo("https://example.invalid/team--one/project.git");
    let second = git_repo("https://example.invalid/team/one--project.git");
    let home = Home {
        root: home_path.clone(),
    };
    sb(&home_path, &first, &["init"]);
    sb(&home_path, &first, &["add", "--no-files"]);
    let original = home.resolve_repo(None, &first).unwrap();
    let legacy = home
        .repos_dir()
        .join(secondbrain::store::legacy_slug(&original.meta.identity));
    fs::rename(original.dir, &legacy).unwrap();
    sb(&home_path, &first, &["task", "add", "First fixture task"]);

    sb(&home_path, &second, &["add", "--no-files"]);
    sb(&home_path, &second, &["task", "add", "Second fixture task"]);
    let from_first = home.resolve_repo(None, &first).unwrap();
    let from_second = home.resolve_repo(None, &second).unwrap();
    assert_eq!(from_first.dir, legacy);
    assert_ne!(from_first.dir, from_second.dir);
    assert_eq!(from_first.task(1).unwrap().title, "First fixture task");
    assert_eq!(from_second.task(1).unwrap().title, "Second fixture task");
}

#[test]
fn add_preserves_existing_non_utf8_instruction_files() {
    let home = temp("link-home");
    let repo = git_repo("https://example.invalid/team/link-test.git");
    sb(&home, &repo, &["init"]);
    let original = [0xff, 0xfe, b'#', 0, b' ', 0, b'A', 0];
    for (name, kind) in [
        ("AGENTS.md", "agents"),
        ("CLAUDE.md", "claude"),
        ("GEMINI.md", "gemini"),
    ] {
        let path = repo.join(name);
        fs::write(&path, original).unwrap();
        assert!(sb_err(&home, &repo, &["add", "--files", kind]).contains(name));
        assert_eq!(fs::read(path).unwrap(), original);
    }
}

#[test]
fn cli_and_mcp_reject_invalid_task_changes_without_writing() {
    let home_path = temp("task-edit");
    let repo = git_repo("https://example.invalid/team/task-edit.git");
    let home = Home {
        root: home_path.clone(),
    };
    sb(&home_path, &repo, &["init"]);
    sb(&home_path, &repo, &["add", "--no-files"]);
    let error = sb_err(
        &home_path,
        &repo,
        &["task", "add", "Invalid task", "--blocked-by", "42"],
    );
    assert!(error.contains("no task #42"), "{error}");
    let d = home.resolve_repo(None, &repo).unwrap();
    assert!(d.tasks().unwrap().is_empty());
    sb(&home_path, &repo, &["task", "add", "First task"]);
    sb(
        &home_path,
        &repo,
        &["task", "add", "Second task", "--blocked-by", "1"],
    );
    let initial = d.task(2).unwrap();

    let error = sb_err(
        &home_path,
        &repo,
        &["task", "set", "2", "--blocked-by", "", "--status", "bad"],
    );
    assert!(error.contains("unknown status"), "{error}");
    assert_eq!(d.task(2).unwrap(), initial);

    let response = mcp::handle(
        &home,
        &repo,
        &json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "update_task", "arguments": {
                "id": 2, "title": "Changed title", "blocked_by": [4294967296_u64]
            } }
        }),
    )
    .unwrap();
    assert_eq!(response["result"]["isError"], true, "{response}");
    assert_eq!(d.task(2).unwrap(), initial);
}

#[test]
fn repo_search_applies_scope_before_limiting_hits() {
    let home_path = temp("scoped-search");
    let home = Home { root: home_path };
    home.init().unwrap();
    let (many, _) = home.find_or_create("example.invalid/team/many").unwrap();
    let (one, _) = home.find_or_create("example.invalid/team/one").unwrap();
    many.set_context(&"sampleterm\n".repeat(501)).unwrap();
    one.set_context(&format!(
        "sampleterm {}",
        "longer fixture content ".repeat(30)
    ))
    .unwrap();
    secondbrain::index::search(&home, &[many, one], "sampleterm").unwrap();
    let one = home.find("example.invalid/team/one").unwrap().unwrap();
    let hits = secondbrain::index::search(&home, &[one], "sampleterm").unwrap();
    assert_eq!(hits.len(), 1, "{hits:?}");
}

#[test]
fn sync_scans_each_outgoing_commit_on_first_and_later_pushes() {
    for first_push in [true, false] {
        let remote = temp("outgoing-remote");
        git_in(&remote, &["init", "-q", "--bare", "-b", "main"]);
        let url = remote.to_str().unwrap();
        let repo = git_repo("https://example.invalid/team/outgoing.git");
        let home = temp("outgoing-home");
        sb(&home, &repo, &["init"]);
        git_in(&home, &["checkout", "-q", "-B", "main"]);
        git_in(&home, &["config", "user.name", "Fixture"]);
        git_in(
            &home,
            &["config", "user.email", "fixture@localhost.invalid"],
        );
        sb(&home, &repo, &["add", "--no-files"]);
        let before = if first_push {
            git_in(&home, &["remote", "add", "origin", url]);
            String::new()
        } else {
            sb(&home, &repo, &["sync", "--remote", url]);
            git_in(&remote, &["for-each-ref", "refs/heads"])
        };
        let sample = j(&["ghp_", &"a1B2c3D4e5F6g7H8i9J0".repeat(2)]);
        let path = home.join("transient note.md");
        fs::write(&path, format!("fixture {sample}\n")).unwrap();
        git_in(&home, &["add", "-A"]);
        git_in(&home, &["commit", "-qm", "Add a fixture note"]);
        fs::remove_file(path).unwrap();
        git_in(&home, &["add", "-A"]);
        git_in(&home, &["commit", "-qm", "Remove the fixture note"]);

        let error = sb_err(&home, &repo, &["sync"]);
        assert!(
            error.contains("transient note.md") && error.contains("Nothing was pushed"),
            "{error}"
        );
        assert_eq!(git_in(&remote, &["for-each-ref", "refs/heads"]), before);
    }
}

/// Joins pieces at run time so this file never holds a whole secret-looking sample.
fn pieces(parts: &[&str]) -> String {
    parts.concat()
}

#[test]
fn kb_stores_searches_and_organizes_sources_without_opening_originals() {
    let home = temp("kb-home");
    let repo = git_repo("https://github.com/acme/kb-demo.git");
    let files = temp("kb-files");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(
        &home,
        &repo,
        &["task", "add", "Renew the supplier contract"],
    );
    let ignore = fs::read_to_string(home.join(".gitignore")).unwrap();
    assert!(
        ignore.contains("kb.db") && ignore.contains("originals/"),
        "{ignore}"
    );

    let extract = files.join("extract.md");
    fs::write(
        &extract,
        "# Supplier contract\n\nThe renewal is due in March.\n\n## Payment\n\nInvoices are paid within 30 days.\n",
    )
    .unwrap();
    let original = files.join("contract (final).pdf");
    let bytes = [0xff_u8, 0xfe, 0x00, 0x01, 0x02];
    fs::write(&original, bytes).unwrap();
    let added = sb(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Supplier contract 2026",
            "--text-file",
            extract.to_str().unwrap(),
            "--original",
            original.to_str().unwrap(),
            "--para",
            "area",
            "--tag",
            "Contract,2026",
            "--task",
            "1",
            "--summary",
            "Signed contract, renewal due in March",
        ],
    );
    assert!(added.contains("Added source #1"), "{added}");
    let kept: Vec<PathBuf> = fs::read_dir(home.join("originals"))
        .unwrap()
        .flat_map(|d| fs::read_dir(d.unwrap().path()).unwrap())
        .map(|e| e.unwrap().path())
        .collect();
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert!(
        kept[0]
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("1-contract")
    );
    assert_eq!(fs::read(&kept[0]).unwrap(), bytes);
    // sb never opens an original again: removing it changes nothing.
    fs::remove_file(&kept[0]).unwrap();

    let found = sb(&home, &repo, &["kb", "search", "renewal"]);
    assert!(
        found.contains("src#1 [area] Supplier contract 2026"),
        "{found}"
    );
    assert!(
        found.contains("[renewal]"),
        "snippet marks the match: {found}"
    );
    assert!(sb(&home, &repo, &["search", "renewal"]).contains("src#1"));
    assert!(sb(&home, &repo, &["kb", "show", "1", "--chunk", "1"]).contains("due in March"));
    assert!(
        sb(&home, &repo, &["kb", "show", "1"]).contains("Signed contract, renewal due in March")
    );
    assert!(sb(&home, &repo, &["context"]).contains("## Sources (1: project 0, area 1"));
    assert!(sb(&home, &repo, &["kb", "list", "--task", "1"]).contains("#1 [area]"));
    assert!(sb(&home, &repo, &["kb", "list", "--json"]).contains("\"para\": \"area\""));

    assert!(
        sb_err(
            &home,
            &repo,
            &[
                "kb",
                "add",
                "Again",
                "--text-file",
                extract.to_str().unwrap()
            ]
        )
        .contains("already stored as source #1")
    );
    assert!(
        sb_err(
            &home,
            &repo,
            &[
                "kb",
                "add",
                "Bad",
                "--text-file",
                extract.to_str().unwrap(),
                "--para",
                "inbox"
            ]
        )
        .contains("para must be")
    );

    sb(&home, &repo, &["kb", "move", "1", "archive"]);
    assert!(sb(&home, &repo, &["kb", "list", "--para", "area"]).contains("No sources"));
    assert!(sb(&home, &repo, &["kb", "list", "--para", "archive"]).contains("#1 [archive]"));
    let tagged = sb(
        &home,
        &repo,
        &["kb", "tag", "1", "--add", "legal", "--remove", "2026"],
    );
    assert!(
        tagged.contains("contract, legal")
            && !tagged.contains("legal, 2026")
            && !tagged.contains("(2026"),
        "{tagged}"
    );
    assert!(sb(&home, &repo, &["kb", "search", "legal"]).contains("src#1"));
    assert!(sb(&home, &repo, &["kb", "stats"]).contains("1 sources"));

    // The same origin again is a new revision; only the latest is current.
    let one = files.join("one.md");
    let two = files.join("two.md");
    fs::write(&one, "Pricing page, first version").unwrap();
    fs::write(&two, "Pricing page, second version").unwrap();
    let origin = "https://example.invalid/pricing";
    sb(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Pricing",
            "--text-file",
            one.to_str().unwrap(),
            "--origin",
            origin,
        ],
    );
    let second = sb(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Pricing",
            "--text-file",
            two.to_str().unwrap(),
            "--origin",
            origin,
        ],
    );
    assert!(second.contains("rev 2"), "{second}");
    let listing = sb(&home, &repo, &["kb", "list"]);
    assert!(
        listing.contains("#3") && !listing.contains("#2 "),
        "{listing}"
    );
    let removed = sb(&home, &repo, &["kb", "rm", "3"]);
    assert!(removed.contains("Removed source #3"));
    assert!(
        sb(&home, &repo, &["kb", "list"]).contains("#2 "),
        "the earlier revision is current again"
    );

    // Text that looks like a secret needs an explicit decision.
    let secret = files.join("secret.md");
    fs::write(
        &secret,
        format!(
            "token {}\n",
            pieces(&["ghp_", "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"])
        ),
    )
    .unwrap();
    let refused = sb_err(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Token note",
            "--text-file",
            secret.to_str().unwrap(),
        ],
    );
    assert!(refused.contains("secrets or personal data"), "{refused}");
    assert!(
        sb(
            &home,
            &repo,
            &[
                "kb",
                "add",
                "Token note",
                "--text-file",
                secret.to_str().unwrap(),
                "--allow-sensitive"
            ]
        )
        .contains("Added source")
    );

    // Originals are never deleted by sb.
    let again = files.join("again.md");
    fs::write(&again, "Second original").unwrap();
    let doc = files.join("doc.docx");
    fs::write(&doc, b"PK").unwrap();
    sb(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Doc",
            "--text-file",
            again.to_str().unwrap(),
            "--original",
            doc.to_str().unwrap(),
        ],
    );
    let id = sb(&home, &repo, &["kb", "list", "--para", "resource"]);
    let doc_id = id
        .lines()
        .find(|l| l.contains("Doc"))
        .unwrap()
        .trim_start_matches("- #")
        .split(' ')
        .next()
        .unwrap()
        .to_string();
    let removed = sb(&home, &repo, &["kb", "rm", &doc_id]);
    assert!(removed.contains("never deletes originals"), "{removed}");
    let left = fs::read_dir(home.join("originals"))
        .unwrap()
        .flat_map(|d| fs::read_dir(d.unwrap().path()).unwrap())
        .count();
    assert_eq!(left, 1);
    assert!(sb(&home, &repo, &["kb", "stats"]).contains("originals without a source"));
}

#[test]
fn mcp_sources_round_trip() {
    let home = temp("kb-mcp-home");
    let repo = git_repo("https://github.com/acme/kb-mcp.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    let store = Home { root: home.clone() };
    let tool = |name: &str, args: serde_json::Value| {
        let r = mcp::handle(
            &store,
            &repo,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}),
        )
        .unwrap();
        (
            r["result"]["isError"].as_bool().unwrap(),
            r["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_string(),
        )
    };
    let (err, text) = tool(
        "add_source",
        json!({"title": "Meeting notes", "text": "# Notes\n\nWe agreed to ship the beta on Friday.", "kind": "chat",
               "tags": ["meeting", "beta"], "summary": "Beta ship date", "para": "project"}),
    );
    assert!(!err && text.contains("Added source #1"), "{text}");
    let (err, text) = tool("search_sources", json!({"query": "beta friday"}));
    assert!(
        !err && text.contains("src#1 [project] Meeting notes"),
        "{text}"
    );
    let (err, text) = tool("get_source", json!({"id": 1, "chunk": 1}));
    assert!(!err && text.contains("ship the beta"), "{text}");
    let (err, text) = tool(
        "update_source",
        json!({"id": 1, "para": "archive", "add_tags": ["done"], "remove_tags": ["beta"]}),
    );
    assert!(
        !err && text.contains("[archive]") && text.contains("meeting, done"),
        "{text}"
    );
    let (err, text) = tool("list_sources", json!({"para": "archive"}));
    assert!(!err && text.contains("#1"), "{text}");
    let (err, text) = tool("add_source", json!({"title": "", "text": "x"}));
    assert!(err && text.contains("needs a title"), "{text}");
    let (err, text) = tool(
        "add_source",
        json!({"title": "T", "text": "x", "original_path": "relative.pdf"}),
    );
    assert!(err && text.contains("absolute"), "{text}");
    let (err, text) = tool("get_source", json!({"id": 99}));
    assert!(err && text.contains("no source #99"), "{text}");
}

#[test]
fn kb_compact_removes_duplicates_and_search_still_finds_the_kept_text() {
    let home = temp("kbc-home");
    let repo = git_repo("https://github.com/acme/kbc-demo.git");
    let files = temp("kbc-files");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    let words = |p: &str, n: usize| {
        (0..n)
            .map(|i| format!("{p}{i}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let add = |title: &str, text: String, extra: &[&str]| {
        let file = files.join(format!("{title}.md"));
        fs::write(&file, text).unwrap();
        let mut args = vec!["kb", "add", title, "--text-file", file.to_str().unwrap()];
        args.extend_from_slice(extra);
        sb(&home, &repo, &args)
    };
    let section = |heading: &str, body: String| format!("# {heading}\n\n{body}\n\n");
    let alpha = section("Alpha", words("alpha", 150));
    add(
        "One",
        format!("{alpha}{}", section("Beta", words("beta", 150))),
        &[],
    );
    add(
        "Two",
        format!("{alpha}{}", section("Gamma", words("gamma", 150))),
        &[],
    );
    let delta = format!("{} extra", words("delta", 149));
    add(
        "Three",
        format!(
            "{}{}",
            section("Delta", words("delta", 150)),
            section("Epsilon", words("epsilon", 150))
        ),
        &[],
    );
    add(
        "Four",
        format!(
            "{}{}",
            section("Delta", delta),
            section("Zeta", words("zeta", 150))
        ),
        &[],
    );
    let origin = ["--origin", "https://example.invalid/pricing"];
    add("Pricing", "Pricing page, oldrevisionword".into(), &origin);
    add("Pricing", "Pricing page, newrevisionword".into(), &origin);
    add(
        "Blob",
        format!("# Notes\n\nkeepme words\n\n{}\n", "QUJD".repeat(60)),
        &["--allow-sensitive"],
    );

    let dry = sb(&home, &repo, &["kb", "compact", "--dry-run"]);
    for expected in [
        "Dry run",
        "superseded revisions: 1",
        "exact duplicate chunks: 1",
        "near-duplicate chunks: 1",
        "base64 blobs: 1",
    ] {
        assert!(dry.contains(expected), "{expected}: {dry}");
    }
    assert!(sb(&home, &repo, &["kb", "show", "2"]).contains("[chunk 1/2]"));
    assert!(sb(&home, &repo, &["kb", "show", "5"]).contains("oldrevisionword"));
    assert!(sb(&home, &repo, &["kb", "show", "7"]).contains("QUJDQUJD"));

    let done = sb(&home, &repo, &["kb", "compact"]);
    assert!(done.contains("Compacted"), "{done}");
    assert!(sb(&home, &repo, &["kb", "show", "2"]).contains("[chunk 1/1]"));
    assert!(sb(&home, &repo, &["kb", "show", "4"]).contains("[chunk 1/1]"));
    assert!(sb(&home, &repo, &["kb", "show", "1"]).contains("[chunk 2/2]"));
    assert!(
        sb_err(&home, &repo, &["kb", "show", "5"]).contains("no source #5"),
        "the superseded revision is gone"
    );
    let blob = sb(&home, &repo, &["kb", "show", "7"]);
    assert!(
        blob.contains("keepme") && !blob.contains("QUJDQUJD"),
        "{blob}"
    );

    assert!(sb(&home, &repo, &["kb", "search", "gamma7"]).contains("src#2"));
    assert!(sb(&home, &repo, &["kb", "search", "zeta7"]).contains("src#4"));
    assert!(sb(&home, &repo, &["kb", "search", "newrevisionword"]).contains("src#6"));
    let kept = sb(&home, &repo, &["kb", "search", "alpha7"]);
    assert!(kept.contains("src#1") && !kept.contains("src#2"), "{kept}");
    let kept = sb(&home, &repo, &["kb", "search", "delta7"]);
    assert!(kept.contains("src#3") && !kept.contains("src#4"), "{kept}");

    let again = sb(&home, &repo, &["kb", "compact"]);
    assert!(
        again.contains("superseded revisions: 0")
            && again.contains("exact duplicate chunks: 0")
            && again.contains("near-duplicate chunks: 0"),
        "{again}"
    );
}

#[test]
fn repository_pack_round_trips_between_homes_and_refuses_unsafe_packs() {
    let home = temp("pack-home");
    let other = temp("pack-other");
    let repo = git_repo("https://github.com/acme/pack-demo.git");
    let files = temp("pack-files");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(
        &home,
        &repo,
        &["task", "add", "Renew the supplier contract"],
    );
    sb(&home, &repo, &["decide", "Keep sources per repository"]);
    let dossier = fs::read_dir(home.join("repos"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    fs::write(dossier.join("context.md"), "Pack demo state\n").unwrap();
    let extract = files.join("extract.md");
    fs::write(&extract, "# Contract\n\nThe renewal is due in March.\n").unwrap();
    let original = files.join("contract.pdf");
    fs::write(&original, [0xff_u8, 0x00, 0x01]).unwrap();
    sb(
        &home,
        &repo,
        &[
            "kb",
            "add",
            "Supplier contract",
            "--text-file",
            extract.to_str().unwrap(),
            "--original",
            original.to_str().unwrap(),
            "--tag",
            "contract",
            "--task",
            "1",
        ],
    );

    // Refusals on export.
    let inside = repo.join("out.sbkb");
    let sqlite = |out: &Path| {
        vec![
            "export".to_string(),
            "--format".into(),
            "sqlite".into(),
            "--out".into(),
            out.to_str().unwrap().into(),
        ]
    };
    let run_with = |home: &Path, cwd: &Path, args: Vec<String>| {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        sb(home, cwd, &refs)
    };
    let err_with = |home: &Path, cwd: &Path, args: Vec<String>| {
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        sb_err(home, cwd, &refs)
    };
    let e = err_with(&home, &repo, sqlite(&inside));
    assert!(e.contains("inside a Git repository"), "{e}");
    assert!(!inside.exists());
    let e = sb_err(&home, &repo, &["export", "--format", "sqlite"]);
    assert!(e.contains("--out"), "{e}");
    let md_in_repo = repo.join("md");
    let e = sb_err(
        &home,
        &repo,
        &["kb", "export", "--out", md_in_repo.to_str().unwrap()],
    );
    assert!(e.contains("inside a Git repository"), "{e}");

    let pack = files.join("demo.sbkb");
    let done = run_with(&home, &repo, sqlite(&pack));
    assert!(done.contains("1 source(s)"), "{done}");
    let e = err_with(&home, &repo, sqlite(&pack));
    assert!(e.contains("exists already"), "{e}");
    let bytes = fs::read(&pack).unwrap();
    assert!(
        !String::from_utf8_lossy(&bytes).contains("contract.pdf"),
        "no original name in the pack"
    );
    let pack_arg = pack.to_str().unwrap();

    // Round trip into a second home.
    sb(&other, &files, &["init"]);
    let dry = sb(&other, &files, &["import", "--pack", pack_arg, "--dry-run"]);
    assert!(
        dry.contains("Dry run") && dry.contains("would create"),
        "{dry}"
    );
    assert_eq!(fs::read_dir(other.join("repos")).unwrap().count(), 0);
    let done = sb(&other, &files, &["import", "--pack", pack_arg]);
    assert!(done.contains("sources: 1 imported"), "{done}");
    let imported = fs::read_dir(other.join("repos"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(
        fs::read_to_string(imported.join("context.md")).unwrap(),
        "Pack demo state\n"
    );
    let repo_spec = ["--repo", "github.com/acme/pack-demo"];
    let with_repo = |args: &[&str]| {
        let mut all: Vec<&str> = args.to_vec();
        all.extend_from_slice(&repo_spec);
        sb(&other, &files, &all)
    };
    assert!(with_repo(&["kb", "list"]).contains("Supplier contract"));
    assert!(with_repo(&["kb", "search", "renewal"]).contains("Supplier contract"));
    assert!(with_repo(&["task", "list"]).contains("Renew the supplier contract"));
    assert!(
        fs::read_to_string(imported.join("decisions.md"))
            .unwrap()
            .contains("Keep sources per repository")
    );
    assert_eq!(
        fs::read_to_string(imported.join("paths.json"))
            .unwrap()
            .trim(),
        "[]",
        "no checkout path travels in a pack"
    );
    assert!(!other.join("originals").exists());

    // Merging again adds nothing.
    let again = sb(&other, &files, &["import", "--pack", pack_arg]);
    assert!(again.contains("sources: 0 imported"), "{again}");
    assert!(again.contains("1 already present"), "{again}");
    assert_eq!(
        fs::read_to_string(imported.join("decisions.md"))
            .unwrap()
            .matches("Keep sources")
            .count(),
        1
    );

    // Replace backs up first.
    let replaced = sb(&other, &files, &["import", "--pack", pack_arg, "--replace"]);
    assert!(
        replaced.contains("Backup of the previous dossier"),
        "{replaced}"
    );
    assert!(other.join("backups").is_dir());
    assert!(with_repo(&["kb", "list"]).contains("Supplier contract"));

    // Markdown export.
    let md = files.join("md");
    let done = sb(
        &home,
        &repo,
        &[
            "kb",
            "export",
            "--format",
            "md",
            "--out",
            md.to_str().unwrap(),
        ],
    );
    assert!(done.contains("1 source(s)"), "{done}");
    let file = fs::read_dir(&md).unwrap().next().unwrap().unwrap().path();
    let text = fs::read_to_string(file).unwrap();
    assert!(
        text.starts_with("---\nid: 1\ntitle: \"Supplier contract\""),
        "{text}"
    );
    assert!(text.contains("renewal is due in March"));
    let e = sb_err(
        &home,
        &repo,
        &["kb", "export", "--out", md.to_str().unwrap()],
    );
    assert!(e.contains("not empty"), "{e}");

    // Refusals on import: other repository, newer schema, secrets, unexpected file, not a pack.
    let third = git_repo("https://github.com/acme/elsewhere.git");
    sb(&home, &third, &["add", "--no-files"]);
    let e = sb_err(
        &home,
        &third,
        &[
            "import",
            "--pack",
            pack_arg,
            "--repo",
            "github.com/acme/elsewhere",
        ],
    );
    assert!(e.contains("belongs to"), "{e}");
    let tamper = |name: &str, sql: &str| {
        let copy = files.join(name);
        fs::copy(&pack, &copy).unwrap();
        rusqlite::Connection::open(&copy)
            .unwrap()
            .execute_batch(sql)
            .unwrap();
        copy
    };
    let newer = tamper(
        "newer.sbkb",
        "UPDATE meta SET value = '99' WHERE key = 'schema_version'",
    );
    let e = sb_err(
        &other,
        &files,
        &["import", "--pack", newer.to_str().unwrap()],
    );
    assert!(e.contains("newer SecondBrain"), "{e}");
    let secret = pieces(&["AKIA", "IOSFODNN7", "EXAMPLE"]);
    let leaky = tamper(
        "leaky.sbkb",
        &format!("UPDATE chunks SET text = text || ' {secret}'"),
    );
    let e = sb_err(
        &other,
        &files,
        &["import", "--pack", leaky.to_str().unwrap(), "--replace"],
    );
    assert!(e.contains("secrets or personal data"), "{e}");
    let odd = tamper(
        "odd.sbkb",
        "INSERT INTO dossier_files (path, content) VALUES ('paths.json', '[]')",
    );
    let e = sb_err(&other, &files, &["import", "--pack", odd.to_str().unwrap()]);
    assert!(e.contains("unexpected file"), "{e}");
    let plain = files.join("plain.sbkb");
    fs::write(&plain, "not a database").unwrap();
    let e = sb_err(
        &other,
        &files,
        &["import", "--pack", plain.to_str().unwrap()],
    );
    assert!(
        e.contains("not a SecondBrain pack") || e.contains("opening"),
        "{e}"
    );
}

#[test]
fn a_moved_local_repository_keeps_its_dossier_through_relink() {
    let home = temp("relink-home");
    let parent = temp("relink-parent");
    let old = parent.join("first");
    fs::create_dir_all(&old).unwrap();
    assert!(
        Command::new("git")
            .arg("-C")
            .arg(&old)
            .args(["init", "-q"])
            .status()
            .unwrap()
            .success()
    );
    sb(&home, &old, &["init"]);
    sb(&home, &old, &["add", "--no-files"]);
    sb(&home, &old, &["task", "add", "Keep me"]);
    let identity = sb(&home, &old, &["repos"])
        .split_whitespace()
        .next()
        .unwrap()
        .to_string();
    assert!(identity.starts_with("local/first@"), "{identity}");

    let new = parent.join("second");
    fs::rename(&old, &new).unwrap();

    // Without relink the moved folder looks like a new, empty repository.
    assert!(sb_err(&home, &new, &["task", "list"]).contains("not added yet"));
    assert!(sb_err(&home, &new, &["doctor"]).contains("sb relink"));

    // A GitHub repository has nothing to relink.
    let out = sb(&home, &new, &["relink", &identity]);
    assert!(out.contains("Relinked") && out.contains(&identity), "{out}");
    assert!(sb(&home, &new, &["task", "list"]).contains("Keep me"));
    assert!(sb(&home, &new, &["repos"]).contains(new.file_name().unwrap().to_str().unwrap()));
    assert!(!sb(&home, &new, &["doctor"]).contains("no longer exists"));
    // Running it again changes nothing.
    assert!(sb(&home, &new, &["relink", &identity]).contains("Relinked"));
    assert!(sb(&home, &new, &["task", "list"]).contains("Keep me"));
}

#[test]
fn a_recreated_folder_does_not_attach_to_the_old_local_dossier() {
    let home = temp("relink-stale-home");
    let parent = temp("relink-stale-parent");
    let old = parent.join("first");
    let git = |dir: &std::path::Path, args: &[&str]| {
        assert!(
            Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(["-c", "user.name=t", "-c", "user.email=t@example.test"])
                .args(args)
                .status()
                .unwrap()
                .success()
        );
    };
    fs::create_dir_all(&old).unwrap();
    git(&old, &["init", "-q"]);
    git(&old, &["commit", "-q", "--allow-empty", "-m", "one"]);
    sb(&home, &old, &["init"]);
    sb(&home, &old, &["add", "--no-files"]);
    sb(&home, &old, &["task", "add", "Keep me"]);
    let identity = sb(&home, &old, &["repos"])
        .split_whitespace()
        .next()
        .unwrap()
        .to_string();
    let new = parent.join("second");
    fs::rename(&old, &new).unwrap();
    sb(&home, &new, &["relink", &identity]);
    assert!(sb(&home, &new, &["task", "list"]).contains("Keep me"));

    // The folder is deleted and recreated as a different repository with its own history.
    fs::remove_dir_all(&new).unwrap();
    fs::create_dir_all(&new).unwrap();
    git(&new, &["init", "-q"]);
    git(&new, &["commit", "-q", "--allow-empty", "-m", "other"]);
    assert!(sb_err(&home, &new, &["task", "list"]).contains("not added yet"));
}

#[test]
fn relink_refuses_a_github_dossier_and_a_folder_that_holds_work() {
    let home = temp("relink-refuse-home");
    let gh = git_repo("https://example.invalid/fixtures/remote.git");
    sb(&home, &gh, &["init"]);
    sb(&home, &gh, &["add", "--no-files"]);
    let err = sb_err(&home, &gh, &["relink", "remote"]);
    assert!(err.contains("GitHub remote"), "{err}");

    let a = temp("relink-a");
    let b = temp("relink-b");
    for p in [&a, &b] {
        assert!(
            Command::new("git")
                .arg("-C")
                .arg(p)
                .args(["init", "-q"])
                .status()
                .unwrap()
                .success()
        );
        sb(&home, p, &["add", "--no-files"]);
        sb(&home, p, &["task", "add", "Own work"]);
    }
    let first = sb(&home, &a, &["repos"]);
    let identity = first
        .lines()
        .find(|l| l.contains(a.file_name().unwrap().to_str().unwrap()))
        .and_then(|l| l.split_whitespace().next())
        .unwrap()
        .to_string();
    let err = sb_err(&home, &b, &["relink", &identity]);
    assert!(err.contains("already belongs"), "{err}");
}

#[test]
fn prepare_queue_and_mcp_prepare_task_make_tasks_eligible() {
    let home = temp("prepare-mcp-home");
    let repo = git_repo("https://example.invalid/fixtures/prepare-mcp.git");
    sb(&home, &repo, &["init"]);
    sb(&home, &repo, &["add", "--no-files"]);
    sb(&home, &repo, &["task", "add", "Autonomous"]);
    sb(
        &home,
        &repo,
        &[
            "task",
            "add",
            "Needs input",
            "--needs-user",
            "--accept",
            "cargo check",
        ],
    );
    sb(&home, &repo, &["task", "add", "Held", "--needs-user"]);
    sb(&home, &repo, &["task", "add", "Done one", "--needs-user"]);
    sb(&home, &repo, &["task", "done", "4"]);

    let out = sb(&home, &repo, &["prepare"]);
    assert!(out.contains("2 task(s) to prepare"), "{out}");
    assert!(out.contains("Needs input") && out.contains("Held"), "{out}");
    assert!(
        !out.contains("Autonomous") && !out.contains("Done one"),
        "{out}"
    );
    assert!(out.contains("sb guide prepare"), "{out}");
    let json = sb(&home, &repo, &["prepare", "--json"]);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&json)
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(sb(&home, &repo, &["guide", "prepare"]).contains("prepare_task"));

    let store = Home { root: home.clone() };
    let tool = |name: &str, args: serde_json::Value| {
        let r = mcp::handle(
            &store,
            &repo,
            &json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}),
        )
        .unwrap();
        (
            r["result"]["isError"].as_bool().unwrap(),
            r["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_string(),
        )
    };
    let (err, text) = tool("prepare_queue", json!({}));
    assert!(
        !err && text.contains("Needs input") && !text.contains("Autonomous"),
        "{text}"
    );

    let (err, text) = tool(
        "prepare_task",
        json!({"id": 2, "scope": "", "acceptance": "x", "decision": "ready"}),
    );
    assert!(err && text.contains("required"), "{text}");
    let (err, text) = tool(
        "prepare_task",
        json!({"id": 2, "scope": "cli/src", "acceptance": "tests pass", "authorizations": "none needed", "decision": "maybe"}),
    );
    assert!(err && text.contains("ready or hold"), "{text}");
    let (err, text) = tool(
        "prepare_task",
        json!({"id": 3, "scope": "docs", "acceptance": "reviewed", "inputs": "missing logo", "decision": "hold"}),
    );
    assert!(!err, "{text}");
    let (err, text) = tool(
        "prepare_task",
        json!({"id": 2, "scope": "cli/src", "acceptance": "tests pass", "authorizations": "none needed", "decision": "ready"}),
    );
    assert!(!err && text.contains("sb run --task 2 --dry-run"), "{text}");

    let dossier = store.resolve_repo(None, &repo).unwrap();
    let ready = dossier.task(2).unwrap();
    assert!(!ready.needs_user);
    assert_eq!(ready.accept.as_deref(), Some("cargo check"));
    assert!(
        ready.body.contains("**Scope**\ncli/src")
            && ready.body.contains("**Authorizations**\nnone needed")
    );
    let held = dossier.task(3).unwrap();
    assert!(held.needs_user && held.body.contains("**Inputs**\nmissing logo"));
    let (err, text) = tool(
        "prepare_task",
        json!({"id": 4, "scope": "a", "acceptance": "b", "decision": "ready"}),
    );
    assert!(err, "{text}");
    assert!(sb(&home, &repo, &["prepare"]).contains("1 task(s) to prepare"));
}
