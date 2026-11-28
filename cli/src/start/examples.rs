use clap::{Arg, Command};

pub(super) fn invocation(prefix: &str, cmd: &Command, focus: Option<&Arg>) -> String {
    let focused = focus.map(|arg| arg.get_id().as_str());
    let mut example = prefix.to_string();
    if prefix == "sb start" && focused == Some("path") {
        example.push_str(" work");
    }
    if prefix == "sb context" && focused == Some("if_empty") {
        example.push_str(" --set");
    }
    for arg in cmd.get_arguments() {
        if arg.is_required_set() || focused == Some(arg.get_id().as_str()) {
            example.push(' ');
            if let Some(long) = arg.get_long() {
                example.push_str("--");
                example.push_str(long);
                if !arg.get_action().takes_values() {
                    continue;
                }
                example.push(' ');
            }
            example.push_str(value(prefix, arg));
        }
    }
    match (prefix, focused) {
        ("sb task", _) => example.push_str(" list"),
        ("sb kb", _) => example.push_str(" list"),
        ("sb kb compact", None) => example.push_str(" --dry-run"),
        ("sb import", Some("repo" | "merge" | "replace")) => {
            example.push_str(" --pack ./team.sbkb")
        }
        ("sb kb add", focus) if focus != Some("text_file") => {
            example = format!("echo \"# Extracted text\" | {example}");
        }
        ("sb rules", _) => example.push_str(" show"),
        ("sb skill", _) => example.push_str(" list"),
        ("sb guide", None) => example.push_str(" onboarding"),
        ("sb mcp install" | "sb mcp config" | "sb mcp uninstall", None) => {
            example.push_str(" --client codex");
        }
        ("sb task set", None | Some("id" | "repo")) => example.push_str(" --status blocked"),
        ("sb skill add", None | Some("name")) => example.push_str(" --file ./SKILL.md"),
        ("sb context", Some("set" | "if_empty")) => {
            example = format!("echo \"The API starts in src/main.rs\" | {example}");
        }
        ("sb rules set", _) => {
            example = format!("echo \"Run cargo test before committing.\" | {example}");
        }
        ("sb rules sync", Some("check")) => {
            example.push_str(" --agent-file ./agent-profile/AGENTS.md")
        }
        ("sb run", None) => example.push_str(" --dry-run"),
        ("sb run", Some(arg)) if arg != "dry_run" => {
            if !matches!(arg, "agent" | "agent_cmd") {
                example.push_str(" --agent codex");
            }
            if !matches!(arg, "agent_cmd" | "model") {
                example.push_str(" --model gpt-6.2-sol");
            }
            if !matches!(arg, "task" | "limit" | "all") {
                example.push_str(" --limit 1");
            }
        }
        _ => {}
    }
    example
}

fn value(prefix: &str, arg: &Arg) -> &'static str {
    match (prefix, arg.get_id().as_str()) {
        (_, "area") => "work",
        ("sb start", "path") => "task add",
        (_, "path") => "./sample-project",
        (_, "files") => "agents,gemini",
        (_, "repo") => "sample-project",
        (_, "budget") => "500",
        (_, "text") => "\"Use SQLite for search because it works offline\"",
        (_, "query") => "\"login redirect\"",
        (_, "topic") => "chat",
        ("sb migrate", "file") => "./secondbrain-v4.json",
        (_, "file") => "./SKILL.md",
        (_, "agent_file") => "./agent-profile/AGENTS.md",
        (_, "agent") => "codex",
        (_, "agent_cmd") => "./my-agent",
        (_, "id" | "task") => "7",
        (_, "limit") => "3",
        (_, "model") => "gpt-6.2-sol",
        (_, "effort") => "high",
        (_, "timeout") => "45",
        (_, "remote") => "https://example.invalid/my-private-dossier.git",
        ("sb kb export", "format") => "md",
        ("sb kb export", "out") => "../sample-sources",
        (_, "format") => "json",
        (_, "pack") => "./team.sbkb",
        (_, "out") => "../sample-dossier.md",
        (_, "client") => "codex",
        ("sb kb add", "title") => "\"Supplier contract 2026\"",
        (_, "title") => "\"Fix the login redirect\"",
        (_, "text_file") => "./extract.md",
        (_, "original") => "./contract.pdf",
        (_, "origin") => "https://example.invalid/contract",
        (_, "kind") => "file",
        (_, "para") => "archive",
        (_, "tag" | "add" | "remove") => "contract,2026",
        (_, "summary") => "\"Signed supplier contract; renewal due in March\"",
        (_, "chunk") => "2",
        (_, "body") => "\"Preserve the requested return URL\"",
        (_, "priority") => "2",
        (_, "blocked_by") => "3,5",
        (_, "accept") => "\"cargo test\"",
        (_, "by") => "docs-agent",
        (_, "minutes") => "15",
        (_, "older_than") => "90",
        (_, "status") => "blocked",
        (_, "needs_user") => "true",
        (_, "name") => "review-checklist",
        _ => "example",
    }
}
