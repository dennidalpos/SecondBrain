//! `sb mcp install|uninstall|config`: registers `sb mcp` with an agent client.
//!
//! Each client has one known configuration file per OS; nothing on the computer is searched.
//! The entry uses the absolute path of this `sb` binary, because desktop apps do not see the
//! shell PATH. Other servers and settings in the file are kept as they are; the original file
//! is copied to `<file>.sb-backup` before the first change.

use crate::store::write_atomic;
use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Map, Value, json};
use std::fs;
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const SERVER: &str = "secondbrain";

#[derive(Clone, Copy, Debug, PartialEq)]
enum Format {
    /// `{ "<key>": { "secondbrain": {...} } }`
    Json { key: &'static str, typed: bool },
    /// `[mcp_servers.secondbrain]` in a TOML file.
    CodexToml,
    /// The client's own `claude mcp add` command.
    ClaudeCli,
}

#[derive(Clone, Copy, Debug)]
pub struct Client {
    pub id: &'static str,
    pub name: &'static str,
    format: Format,
}

pub const CLIENTS: &[Client] = &[
    Client {
        id: "claude-desktop",
        name: "Claude Desktop",
        format: Format::Json {
            key: "mcpServers",
            typed: false,
        },
    },
    Client {
        id: "claude-code",
        name: "Claude Code (user scope)",
        format: Format::ClaudeCli,
    },
    Client {
        id: "codex",
        name: "Codex",
        format: Format::CodexToml,
    },
    Client {
        id: "cursor",
        name: "Cursor",
        format: Format::Json {
            key: "mcpServers",
            typed: false,
        },
    },
    Client {
        id: "vscode",
        name: "VS Code (user mcp.json)",
        format: Format::Json {
            key: "servers",
            typed: true,
        },
    },
    Client {
        id: "windsurf",
        name: "Windsurf",
        format: Format::Json {
            key: "mcpServers",
            typed: false,
        },
    },
    Client {
        id: "gemini",
        name: "Gemini CLI",
        format: Format::Json {
            key: "mcpServers",
            typed: false,
        },
    },
];

/// The base folders the client paths are built from.
pub struct Dirs {
    pub home: PathBuf,
    /// %APPDATA% on Windows, ~/Library/Application Support on macOS, $XDG_CONFIG_HOME or ~/.config elsewhere.
    pub config: PathBuf,
}

impl Dirs {
    pub fn from_env() -> Result<Dirs> {
        let var = |k: &str| {
            std::env::var_os(k)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let home = if cfg!(windows) {
            var("USERPROFILE").or_else(|| var("HOME"))
        } else {
            var("HOME")
        }
        .ok_or_else(|| anyhow!("cannot find your home folder"))?;
        let config = if cfg!(windows) {
            var("APPDATA").unwrap_or_else(|| home.join("AppData").join("Roaming"))
        } else if cfg!(target_os = "macos") {
            home.join("Library").join("Application Support")
        } else {
            var("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"))
        };
        Ok(Dirs { home, config })
    }
}

pub fn find(id: &str) -> Result<Client> {
    CLIENTS.iter().copied().find(|c| c.id == id).ok_or_else(|| {
        anyhow!(
            "unknown client '{id}'; use one of: {}",
            CLIENTS.iter().map(|c| c.id).collect::<Vec<_>>().join(", ")
        )
    })
}

/// The configuration file of a client (None for clients configured through their own command).
pub fn config_path(client: &Client, dirs: &Dirs) -> Option<PathBuf> {
    Some(match client.id {
        "claude-desktop" => dirs
            .config
            .join("Claude")
            .join("claude_desktop_config.json"),
        "codex" => dirs.home.join(".codex").join("config.toml"),
        "cursor" => dirs.home.join(".cursor").join("mcp.json"),
        "vscode" => dirs.config.join("Code").join("User").join("mcp.json"),
        "windsurf" => dirs
            .home
            .join(".codeium")
            .join("windsurf")
            .join("mcp_config.json"),
        "gemini" => dirs.home.join(".gemini").join("settings.json"),
        _ => return None,
    })
}

/// What the client should start: this binary with `mcp`, plus SB_HOME when it is not the default.
pub struct Launch {
    pub command: String,
    pub sb_home: Option<String>,
}

fn entry(launch: &Launch, typed: bool) -> Value {
    let mut e = Map::new();
    if typed {
        e.insert("type".into(), json!("stdio"));
    }
    e.insert("command".into(), json!(launch.command));
    e.insert("args".into(), json!(["mcp"]));
    if let Some(h) = &launch.sb_home {
        e.insert("env".into(), json!({ "SB_HOME": h }));
    }
    Value::Object(e)
}

/// Adds or replaces the server in a JSON config text; None when it is already identical.
pub fn json_install(text: &str, key: &str, value: Value) -> Result<Option<String>> {
    let mut root: Value = if text.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(text).context(
            "the file is not plain JSON (comments or trailing commas?); add the entry by hand",
        )?
    };
    let obj = root
        .as_object_mut()
        .ok_or_else(|| anyhow!("the file is not a JSON object"))?;
    let servers = obj.entry(key.to_string()).or_insert_with(|| json!({}));
    let servers = servers
        .as_object_mut()
        .ok_or_else(|| anyhow!("'{key}' is not a JSON object"))?;
    if servers.get(SERVER) == Some(&value) {
        return Ok(None);
    }
    servers.insert(SERVER.into(), value);
    Ok(Some(serde_json::to_string_pretty(&root)? + "\n"))
}

/// Removes the server from a JSON config text; None when it is not there.
pub fn json_uninstall(text: &str, key: &str) -> Result<Option<String>> {
    if text.trim().is_empty() {
        return Ok(None);
    }
    let mut root: Value = serde_json::from_str(text)
        .context("the file is not plain JSON; remove the entry by hand")?;
    let removed = root
        .get_mut(key)
        .and_then(Value::as_object_mut)
        .and_then(|s| s.shift_remove(SERVER))
        .is_some();
    Ok(removed
        .then(|| serde_json::to_string_pretty(&root).map(|t| t + "\n"))
        .transpose()?)
}

fn toml_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| format!("\"{s}\""))
}

fn codex_block(launch: &Launch) -> String {
    let mut b = format!(
        "[mcp_servers.{SERVER}]\ncommand = {}\nargs = [\"mcp\"]\n",
        toml_string(&launch.command)
    );
    if let Some(h) = &launch.sb_home {
        b.push_str(&format!("env = {{ SB_HOME = {} }}\n", toml_string(h)));
    }
    b
}

/// The byte range of `[mcp_servers.secondbrain]` and its keys, up to the next table header.
fn codex_span(text: &str) -> Option<(usize, usize)> {
    let header = format!("[mcp_servers.{SERVER}]");
    let mut offset = 0;
    let mut start = None;
    for line in text.split_inclusive('\n') {
        let t = line.trim();
        if start.is_none() && t == header {
            start = Some(offset);
        } else if start.is_some() && t.starts_with('[') {
            return Some((start?, offset));
        }
        offset += line.len();
    }
    start.map(|s| (s, text.len()))
}

pub fn codex_install(text: &str, launch: &Launch) -> Option<String> {
    let block = codex_block(launch);
    match codex_span(text) {
        Some((s, e)) if text[s..e].trim_end() == block.trim_end() => None,
        Some((s, e)) => {
            let tail = &text[e..];
            let sep = if tail.is_empty() { "" } else { "\n" };
            Some(format!("{}{block}{sep}{tail}", &text[..s]))
        }
        None if text.trim().is_empty() => Some(block),
        None => Some(format!("{}\n\n{block}", text.trim_end())),
    }
}

pub fn codex_uninstall(text: &str) -> Option<String> {
    let (s, e) = codex_span(text)?;
    let before = text[..s].trim_end();
    let after = text[e..].trim_start_matches(['\r', '\n']);
    Some(match (before.is_empty(), after.is_empty()) {
        (true, _) => after.to_string(),
        (false, true) => format!("{before}\n"),
        (false, false) => format!("{before}\n\n{after}"),
    })
}

fn write_with_backup(path: &Path, new: &str) -> Result<()> {
    if path.exists() {
        let mut backup = path.as_os_str().to_owned();
        backup.push(".sb-backup");
        let backup = PathBuf::from(backup);
        if !backup.exists() {
            fs::copy(path, &backup).with_context(|| format!("backing up {}", path.display()))?;
        }
    }
    write_atomic(path, new)
}

fn claude_cli(args: &[&str]) -> Result<(bool, String)> {
    let program = crate::run::which("claude")
        .ok_or_else(|| anyhow!("claude is not on the PATH; install Claude Code first"))?;
    let out = Command::new(program)
        .args(args)
        .output()
        .context("running claude mcp")?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    Ok((out.status.success(), text.trim().to_string()))
}

const RESTART: &str = "Restart the client so it loads the change.";

pub fn install(client: &Client, dirs: &Dirs, launch: &Launch) -> Result<String> {
    match client.format {
        Format::ClaudeCli => {
            let _ = claude_cli(&["mcp", "remove", "--scope", "user", SERVER]);
            let mut args = vec!["mcp", "add", "--scope", "user"];
            let env;
            if let Some(h) = &launch.sb_home {
                env = format!("SB_HOME={h}");
                args.extend(["-e", env.as_str()]);
            }
            args.extend([SERVER, launch.command.as_str(), "mcp"]);
            let (ok, text) = claude_cli(&args)?;
            if !ok {
                bail!("claude mcp add failed: {text}");
            }
            Ok(format!(
                "Registered {SERVER} with {} (claude mcp add --scope user). {RESTART}\n",
                client.name
            ))
        }
        Format::Json { key, typed } => {
            let path = config_path(client, dirs).expect("json clients have a path");
            let old = fs::read_to_string(&path).unwrap_or_default();
            let new = json_install(&old, key, entry(launch, typed))
                .with_context(|| format!("{}", path.display()))?;
            match new {
                None => Ok(format!(
                    "{} already has {SERVER}: {}\n",
                    client.name,
                    path.display()
                )),
                Some(new) => {
                    write_with_backup(&path, &new)?;
                    Ok(format!(
                        "Added {SERVER} to {}: {}. {RESTART}\n",
                        client.name,
                        path.display()
                    ))
                }
            }
        }
        Format::CodexToml => {
            let path = config_path(client, dirs).expect("codex has a path");
            let old = fs::read_to_string(&path).unwrap_or_default();
            match codex_install(&old, launch) {
                None => Ok(format!(
                    "{} already has {SERVER}: {}\n",
                    client.name,
                    path.display()
                )),
                Some(new) => {
                    write_with_backup(&path, &new)?;
                    Ok(format!(
                        "Added {SERVER} to {}: {}. {RESTART}\n",
                        client.name,
                        path.display()
                    ))
                }
            }
        }
    }
}

pub fn uninstall(client: &Client, dirs: &Dirs) -> Result<String> {
    let changed = match client.format {
        Format::ClaudeCli => {
            let (ok, text) = claude_cli(&["mcp", "remove", "--scope", "user", SERVER])?;
            if !ok && !text.to_lowercase().contains("no ") {
                bail!("claude mcp remove failed: {text}");
            }
            ok
        }
        Format::Json { key, .. } => {
            let path = config_path(client, dirs).expect("json clients have a path");
            let old = fs::read_to_string(&path).unwrap_or_default();
            match json_uninstall(&old, key).with_context(|| format!("{}", path.display()))? {
                Some(new) => {
                    write_with_backup(&path, &new)?;
                    true
                }
                None => false,
            }
        }
        Format::CodexToml => {
            let path = config_path(client, dirs).expect("codex has a path");
            let old = fs::read_to_string(&path).unwrap_or_default();
            match codex_uninstall(&old) {
                Some(new) => {
                    write_with_backup(&path, &new)?;
                    true
                }
                None => false,
            }
        }
    };
    Ok(if changed {
        format!("Removed {SERVER} from {}. {RESTART}\n", client.name)
    } else {
        format!("{} has no {SERVER} entry.\n", client.name)
    })
}

/// The entry to paste by hand, and where it goes.
pub fn config_text(client: &Client, dirs: &Dirs, launch: &Launch) -> String {
    match client.format {
        Format::ClaudeCli => {
            let env = launch
                .sb_home
                .as_ref()
                .map(|h| format!("-e SB_HOME=\"{h}\" "))
                .unwrap_or_default();
            format!(
                "Run:\nclaude mcp add --scope user {env}{SERVER} \"{}\" mcp\n",
                launch.command
            )
        }
        Format::Json { key, typed } => {
            let path = config_path(client, dirs).expect("json clients have a path");
            let snippet = json!({ key: { SERVER: entry(launch, typed) } });
            format!(
                "Add to {}:\n{}\n",
                path.display(),
                serde_json::to_string_pretty(&snippet).unwrap_or_default()
            )
        }
        Format::CodexToml => {
            let path = config_path(client, dirs).expect("codex has a path");
            format!("Add to {}:\n{}", path.display(), codex_block(launch))
        }
    }
}

/// `--client`, or a choice from the list when a terminal is attached.
pub fn choose(id: Option<&str>) -> Result<Client> {
    if let Some(id) = id {
        return find(id);
    }
    if !std::io::stdin().is_terminal() {
        bail!(
            "choose the client with --client ({})",
            CLIENTS.iter().map(|c| c.id).collect::<Vec<_>>().join(", ")
        );
    }
    eprintln!("Which client should use SecondBrain?");
    for (i, c) in CLIENTS.iter().enumerate() {
        eprintln!("  {}. {} ({})", i + 1, c.name, c.id);
    }
    eprint!("Number: ");
    std::io::stderr().flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let n: usize = line
        .trim()
        .parse()
        .map_err(|_| anyhow!("no client chosen"))?;
    CLIENTS
        .get(n.wrapping_sub(1))
        .copied()
        .ok_or_else(|| anyhow!("no client number {n}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(home: Option<&str>) -> Launch {
        Launch {
            command: r"C:\Tools\sb.exe".into(),
            sb_home: home.map(String::from),
        }
    }

    #[test]
    fn json_keeps_other_servers_and_order() {
        let text = r#"{"theme": "dark", "mcpServers": {"other": {"command": "x"}}, "z": 1}"#;
        let new = json_install(text, "mcpServers", entry(&launch(None), false))
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&new).unwrap();
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["mcpServers"][SERVER]["command"], r"C:\Tools\sb.exe");
        assert_eq!(v["mcpServers"][SERVER]["args"], json!(["mcp"]));
        let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["theme", "mcpServers", "z"]);
        assert!(
            json_install(&new, "mcpServers", entry(&launch(None), false))
                .unwrap()
                .is_none()
        );
        let removed = json_uninstall(&new, "mcpServers").unwrap().unwrap();
        let v: Value = serde_json::from_str(&removed).unwrap();
        assert!(v["mcpServers"].get(SERVER).is_none() && v["mcpServers"].get("other").is_some());
        assert!(json_uninstall(&removed, "mcpServers").unwrap().is_none());
    }

    #[test]
    fn json_new_file_typed_entry_and_errors() {
        let new = json_install("", "servers", entry(&launch(Some("D:/brain")), true))
            .unwrap()
            .unwrap();
        let v: Value = serde_json::from_str(&new).unwrap();
        assert_eq!(v["servers"][SERVER]["type"], "stdio");
        assert_eq!(v["servers"][SERVER]["env"]["SB_HOME"], "D:/brain");
        assert!(json_install("{ // comment\n}", "servers", json!({})).is_err());
        assert!(json_install("[]", "servers", json!({})).is_err());
    }

    #[test]
    fn codex_toml_block() {
        let text = "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"x\"\n";
        let new = codex_install(text, &launch(None)).unwrap();
        assert!(new.starts_with(text.trim_end()));
        assert!(new.contains(
            "[mcp_servers.secondbrain]\ncommand = \"C:\\\\Tools\\\\sb.exe\"\nargs = [\"mcp\"]\n"
        ));
        assert!(codex_install(&new, &launch(None)).is_none());
        let changed = codex_install(&new, &launch(Some("D:/b"))).unwrap();
        assert_eq!(changed.matches("[mcp_servers.secondbrain]").count(), 1);
        assert!(changed.contains("env = { SB_HOME = \"D:/b\" }"));
        let middle = format!("{}\n[profiles.x]\nmodel = \"y\"\n", changed.trim_end());
        let again = codex_install(&middle, &launch(None)).unwrap();
        assert!(again.contains("[profiles.x]") && !again.contains("SB_HOME"));
        assert_eq!(
            codex_uninstall(&again).unwrap(),
            "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"x\"\n\n[profiles.x]\nmodel = \"y\"\n"
        );
        assert!(codex_uninstall(text).is_none());
    }

    #[test]
    fn paths_per_client() {
        let dirs = Dirs {
            home: PathBuf::from("/h"),
            config: PathBuf::from("/c"),
        };
        let p = |id| {
            config_path(&find(id).unwrap(), &dirs).map(|p| p.to_string_lossy().replace('\\', "/"))
        };
        assert_eq!(
            p("claude-desktop").unwrap(),
            "/c/Claude/claude_desktop_config.json"
        );
        assert_eq!(p("vscode").unwrap(), "/c/Code/User/mcp.json");
        assert_eq!(p("cursor").unwrap(), "/h/.cursor/mcp.json");
        assert_eq!(p("codex").unwrap(), "/h/.codex/config.toml");
        assert!(p("claude-code").is_none());
        assert!(find("nope").is_err());
    }
}
