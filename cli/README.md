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
`add_task`, `update_task`, `add_decision`, `set_context`, `search`. Example client entry:

```json
{ "mcpServers": { "secondbrain": { "command": "sb", "args": ["mcp"] } } }
```

## Develop

```sh
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
```
