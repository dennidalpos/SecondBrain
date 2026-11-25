# SecondBrain

Private project context, decisions and tasks for coding agents, kept outside your repositories.

SecondBrain is one small binary, `sb`, for Windows, macOS and Linux. It keeps a dossier per repository in a private folder (`~/.secondbrain`), links each repository's `AGENTS.md` to it, and serves the same data to desktop apps over MCP. It is made for people who work on many repositories, such as freelancers with many clients, and want every agent (Claude Code, Codex, Gemini CLI, Cursor and others) to start from the same notes without committing those notes to the client's repository.

> **Status: 5.0.0-alpha.1.** The command set and the file layout can still change. SecondBrain 4 (the PowerShell scripts, the prompt catalog and the desktop orchestrator) was removed. It stays in the Git history before this release.

## What it does

- **Context per repository:** the current state, dated decisions and tasks, in plain Markdown files you can read, edit and back up with Git.
- **Agent instructions:** `sb add` writes a short managed block in `AGENTS.md` that tells agents to run `sb context`, and creates `CLAUDE.md` as `@AGENTS.md`. Your shared rules (`rules.md`) go into every linked repository with `sb rules sync`.
- **MCP server:** `sb mcp` exposes the same operations to Claude Desktop, Cursor, VS Code, Windsurf and other clients. `sb mcp install` registers it.
- **Unattended runs:** `sb run` works through open tasks one agent process at a time, on a separate branch, with local commits only.
- **Publication check:** `sb check` scans what a push would publish for secrets, personal data and text copied from the dossier.

It does not scan your computer, sync to a cloud, or need a server, a database or a runtime.

## Install

Download the archive for your system from the [releases page](https://github.com/dennidalpos/SecondBrain/releases), check it against `SHA256SUMS`, and put `sb` (`sb.exe` on Windows) in a folder on your PATH.

Archives are named `sb-<version>-<target>`:

| System | Target | Format |
|---|---|---|
| Windows x64 | `x86_64-pc-windows-msvc` | `.zip` |
| Windows ARM64 | `aarch64-pc-windows-msvc` | `.zip` |
| macOS Apple Silicon | `aarch64-apple-darwin` | `.tar.gz` |
| macOS Intel | `x86_64-apple-darwin` | `.tar.gz` |
| Linux x64 (static, any distribution) | `x86_64-unknown-linux-musl` | `.tar.gz` |
| Linux ARM64 (static, any distribution) | `aarch64-unknown-linux-musl` | `.tar.gz` |

The binaries are not signed: macOS may ask you to allow `sb` in System Settings, Privacy & Security (or run `xattr -d com.apple.quarantine sb`), and Windows SmartScreen may warn on first run.

To build from source instead, with Rust 1.88 or later:

```sh
git clone https://github.com/dennidalpos/secondbrain
cargo install --path secondbrain/cli
```

## Quick start

```sh
sb init                          # creates ~/.secondbrain (or SB_HOME), a private Git repository
cd ~/work/client-app && sb add   # registers the repository and links AGENTS.md and CLAUDE.md
sb task add "Fix the login redirect" -p 2
sb decide "Use SQLite for local storage"
sb context                       # what an agent reads at the start of a session
sb mcp install                   # optional: register the MCP server with a desktop app
```

A repository is identified by its `origin` remote (`github.com/owner/name`), so every clone on every machine shares one dossier. Without a remote, the folder name is used.

## Commands

| Command | What it does |
|---|---|
| `sb init` | Create the SecondBrain folder |
| `sb add` / `sb unlink` | Link a repository, or remove the block and pointer files (the dossier stays) |
| `sb repos` | List the repositories |
| `sb context [--set]` | Print the context, or replace it from standard input |
| `sb decide "..."` | Record a dated decision |
| `sb task add/list/show/set/done` | Manage tasks |
| `sb search <text>` | Search context, decisions and tasks across every repository |
| `sb rules sync` | Copy `rules.md` into every linked `AGENTS.md` |
| `sb run` | Run open tasks unattended on an `sb/run-*` branch |
| `sb check` | Scan for secrets, personal data and dossier text before a push |
| `sb mcp [install]` | Serve MCP over stdio, or register it with a client |
| `sb migrate <file>` | Import the open tasks exported from SecondBrain 4 |

Run `sb <command> --help` for the options. [cli/README.md](cli/README.md) covers unattended runs, the publication check rules, the data layout and the MCP clients in detail.

## Data

```text
~/.secondbrain/
  rules.md                          shared rules for every linked AGENTS.md
  repos/github.com--owner--name/
    repo.json                       identity and known checkout folders
    context.md                      current state
    decisions.md                    one dated line per decision
    tasks/0012-fix-login.md         one Markdown file per task
```

Push this folder only to a private remote: it holds your clients' notes.

## Limits

- Alpha: the binaries are not signed or notarized, and the formats can change before 5.0.0.
- `sb run` lets agents edit files only. Commands that need approval, such as tests and builds, are refused, so review the run branch before merging it.
- `sb check` uses built-in rules. It is a safety net, not a replacement for a dedicated secret scanner.

## Develop

```sh
cargo fmt --manifest-path cli/Cargo.toml --check
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path cli/Cargo.toml
```

CI runs the same checks on Ubuntu, macOS and Windows. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
