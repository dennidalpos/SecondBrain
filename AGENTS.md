# Repository instructions: SecondBrain

SecondBrain 5 is a single Rust binary, `sb`, in `cli/`. Everything else in the repository is documentation, CI and agent skills.

## Layout
- `cli/src/`: one module per area (`store`, `task`, `ops`, `block`, `git`, `mcp`, `mcp_install`, `run`, `check`, `migrate`, `cli`, `date`).
- `cli/tests/`: integration tests (`flow`, `run`, `check`), each against a temporary `SB_HOME` and temporary Git repositories.
- `.github/workflows/cli.yml`: fmt, clippy, tests and a release smoke run on Ubuntu, macOS and Windows.
- `.claude/skills/` and `.agents/skills/`: the same skills for Claude Code and for other agents; keep the two copies identical.

## Checks
Run from `cli/` before every commit:
- `cargo fmt --check`
- `cargo clippy --locked --all-targets -- -D warnings`
- `cargo test --locked`
- `cargo run -q -- check` from the repository root: no findings before a push.

## Code style
- Rust 2024 edition, `rust-version` 1.88. Keep dependencies few (anyhow, clap, serde, serde_json, regex); ask before adding one.
- Errors with `anyhow` and context; exit codes through `cli::Exit`. No panics on user input.
- Files are written atomically with `store::write_atomic`. Never touch a user's file outside the managed block or without a backup.
- Product text (help, messages, docs) is in English.
- Test samples that look like secrets or personal data are built from pieces (`j(&[...])`) so scanners do not match the literals.
- `VERSION`, `cli/Cargo.toml` and `CHANGELOG.md` change together.

## Security
- No secrets, personal paths, client names or dossier content in the repository.
- Commits, pushes, tags and publication need the owner's specific authorization.

<!-- secondbrain:begin -->
## SecondBrain

This repository's private context, decisions and tasks live in SecondBrain, outside the repository.

- At the start of a session run `sb context` (MCP tool `get_context`) and work from it.
- Track work with `sb task add`, `sb task list` and `sb task done` (MCP task tools).
- Record durable decisions with `sb decide "..."` and keep the current state with `sb context --set`.
- Never copy dossier content into the repository.
<!-- secondbrain:end -->
