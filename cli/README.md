# SecondBrain 5 (`sb`), alpha

Private project context, decisions and tasks for coding agents, kept outside your repositories.
One binary for Windows, macOS and Linux: a CLI for agents with a shell, and an MCP server for desktop apps.

## Install from source

```sh
cargo install --path cli
```

## Use

```sh
sb init                      # creates ~/.secondbrain (or SB_HOME), a private Git repository
cd my-project && sb add      # registers the repository, writes a block in AGENTS.md and CLAUDE.md -> @AGENTS.md
sb context                   # what an agent reads at the start of a session
sb task add "Fix the login redirect" -p 2
sb task list                 # open tasks; --all, --json
sb task set 1 --status doing
sb task done 1
sb decide "Use SQLite for local storage"
echo "Release 1.2 in review" | sb context --set
sb search login              # across every repository
sb rules sync                # copy ~/.secondbrain/rules.md into every linked AGENTS.md
sb unlink                    # remove the block and pointer files; the dossier stays
sb migrate open-tasks.json   # import the open tasks exported from SecondBrain 4
```

`--repo` accepts an identity (`github.com/owner/name`), its last part (`name`) or a folder.

## Unattended runs

```sh
sb run --dry-run             # which tasks would run: open, todo, not waiting on you
sb run                       # asks which agent to use (claude, codex, gemini found on the PATH)
sb run --agent claude --limit 3 --timeout 30
sb run --agent-cmd "my-agent --flag" --task 12
```

- The working tree must be clean. The run creates an `sb/run-<UTC time>` branch from the current one, or reuses it if you are already on one.
- Each task gets a fresh agent process. The prompt (the task, the project context and the rules) goes to its standard input, and the agent must end with one of three lines: `SB-RESULT: done`, `SB-RESULT: blocked <reason>` or `SB-RESULT: needs-user <what is needed>`.
- Agents may only edit files: Claude Code runs with `--permission-mode acceptEdits`, Gemini CLI with `--approval-mode auto_edit`, Codex in its `workspace-write` sandbox. Commands that need approval, such as tests and builds, are refused.
- `sb` commits each task's changes locally: `<title> (sb #id)` when it is done, `Not done: ...` otherwise. It never pushes. Tasks become `done`, `blocked`, or `todo` with "needs you"; each gets a dated note and the path of its log, which stays in the dossier, not in the repository.
- The run stops when an agent switches branch or its output looks like a usage limit. Without a terminal, `--agent` or `--agent-cmd` is required.
- Review with `git log main..sb/run-...`, then merge or delete the branch.

## Publication check

```sh
sb check                     # working tree + commits not on any remote; exit 2 on findings
sb check --history           # every commit of every branch
sb check --json
sb check --install-hook      # Git pre-push hook that blocks the push on findings (--uninstall-hook)
```

- **Rules:** secrets (private keys; AWS, GitHub, Anthropic, OpenAI, Slack, Google and Stripe live keys; `password = "..."` assignments; credentials in URLs) and personal data (email addresses, home folders such as `C:\Users\<name>` or `/home/<name>`).
- **Dossier leaks:** text from the repository's own dossier (task titles, context and decisions) copied into a file. Only SecondBrain can check this one.
- **Kept quiet on purpose:**
  - placeholders (`${VAR}`, `your-key`, `example`);
  - safe addresses (`example.com`, `.invalid`, noreply);
  - SSH remotes (`git@host:`);
  - personal data in license, notice, lockfile and vendored files;
  - generic credential values in test files;
  - the repository's own user in containers;
  - binary formats.
- **Silencing a reviewed false positive:** add `sb-check: ignore` to the line, or put its fingerprint (shown in brackets) and a reason in a tracked `.sbcheck-ignore`.
- **A secret that was already committed** stays in the history even after you delete the file: rotate it, then rewrite the unpushed commits.

## Data

```text
~/.secondbrain/
  rules.md                          shared rules for every linked AGENTS.md
  repos/github.com--owner--name/
    repo.json                       identity and known checkout folders
    context.md                      current state
    decisions.md                    one dated line per decision
    tasks/0012-fix-login.md         one Markdown file per task (front matter + body)
```

A repository is identified by its `origin` remote, so every clone on every machine shares one dossier.
Plain files: edit them by hand, back them up with Git, and push them only to a private remote.

## MCP

`sb mcp` serves the same operations over stdio: `list_repos`, `get_context`, `list_tasks`, `get_task`,
`add_task`, `update_task`, `add_decision`, `set_context`, `search`.

```sh
sb mcp install               # asks which client; or --client claude-desktop
sb mcp install --client codex
sb mcp uninstall --client cursor
sb mcp config --client vscode   # print the entry to add by hand
sb mcp clients               # supported clients and their files on this computer
```

| Client | Where the entry goes |
|---|---|
| `claude-desktop` | `claude_desktop_config.json` in the Claude folder (`%APPDATA%`, `~/Library/Application Support`, `~/.config`) |
| `claude-code` | `claude mcp add --scope user` |
| `codex` | `~/.codex/config.toml`, `[mcp_servers.secondbrain]` |
| `cursor` | `~/.cursor/mcp.json` |
| `vscode` | the user `mcp.json` in `Code/User` |
| `windsurf` | `~/.codeium/windsurf/mcp_config.json` |
| `gemini` | `~/.gemini/settings.json` |

- **Which binary:** the entry uses the absolute path of the `sb` that ran the command, because desktop apps do not see your shell's PATH. When `--home` or `SB_HOME` is set, the entry also sets `SB_HOME`.
- **Existing configuration:** other servers and settings are kept in their order. Before the first change the original file is copied to `<file>.sb-backup`. Files with comments (JSONC) are refused, so add the entry by hand with `sb mcp config`.
- **No search:** each client has one known file per OS; nothing on the computer is scanned. Restart the client after installing.

## Develop

```sh
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
```
