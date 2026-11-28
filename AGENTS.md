# Repository instructions: SecondBrain

SecondBrain is a single Rust binary, `sb`, in `cli/`. Everything else in the repository is documentation, CI and agent skills.

## Layout
- [README.md](README.md) contains the quick start, [COMMANDS.md](COMMANDS.md) the complete command reference, and [cli/README.md](cli/README.md) the workflows and MCP setup.
- [cli/src/](cli/src/) contains the Rust CLI, persistence, task runner, sync, publication scanner and MCP server.
- [cli/tests/](cli/tests/) contains integration tests that use temporary data folders and Git repositories.
- `.github/workflows/cli.yml`: fmt, clippy, tests and a release smoke run on Ubuntu, macOS and Windows.
- `.github/workflows/release.yml` and `.github/scripts/third_party_licenses.py`: build the six release archives and attach them to a published release (or by hand, for an existing tag).
- `.claude/skills/` and `.agents/skills/`: the same skills for Claude Code and for other agents; keep the two copies identical.

## Checks
Run from `cli/` before every commit:
- `cargo fmt --check`
- `cargo clippy --locked --all-targets -- -D warnings`
- `cargo test --locked`

Before a push, run `cargo run --quiet --manifest-path cli/Cargo.toml -- check` from the repository root and resolve any findings.

## Code style
- Rust 2024 edition, `rust-version` 1.89. Keep dependencies few (anyhow, clap, serde, serde_json, regex, rusqlite with the bundled SQLite for the search index); ask before adding one.
- Errors with `anyhow` and context; exit codes through `cli::Exit`. No panics on user input.
- Files are written atomically with `store::write_atomic`. Never touch a user's file outside the managed block or without a backup.
- Product text (help, messages, docs) is in English.
- Test samples that look like secrets or personal data are built from pieces (`j(&[...])`) so scanners do not match the literals.
- `VERSION`, `cli/Cargo.toml` and `CHANGELOG.md` change together.

## Security
- No secrets, personal paths, client names or dossier content in the repository.
- Commits, pushes, tags and publication need the owner's specific authorization.

<!-- secondbrain:begin -->
<!-- secondbrain:directive-version: v1-00304689082027f9 -->
## SecondBrain

The private context, decisions and tasks for linked repositories live in SecondBrain, outside their checkouts. Apply the repository workflow below when working in a linked checkout.

- At the start of a session run `sb context` (MCP tool `get_context`) and work from it.
- Run `sb start` to check recorded checkouts, refresh managed agent files and see which SecondBrain build is running.
- When asked to run `sb start` in chat, include the full result in the first reply after execution, even in a new session. Use bullet lists for the executable and PATH status, repository, context and tasks, instruction alignment, MCP configuration, health findings, all suggested next steps and every command shown. Put a brief description and an example beside each command and parameter. State when no issues are reported and distinguish MCP configuration from runtime verification.
- When asked to onboard a repository with missing or empty context, read `sb guide onboarding` or call `get_guide` with topic `onboarding`. Inspect the checkout and save the verified starting context in the private dossier.
- When asked to work through tasks in the current chat, read `sb guide chat` or call `get_guide` with topic `chat`.
- Track work with `sb task add`, `sb task list` and `sb task done` (MCP task tools).
- When more than one reasonable scenario exists, interview the user before acting, using the client's structured question tool (function calling or tool use, such as AskUserQuestion). Offer two or three concrete options with their trade-offs and a recommendation. Never choose silently.
- Do not drift from the stated intent on your own initiative. Before adding scope, changing approach or touching files or systems the request did not name, stop, ask and propose alternatives.
- Collect authorizations before a task starts, not during it, so unattended work is not interrupted: push or commit, network or installs, deleting or overwriting data, spending money, secrets or accounts, external services. Ask once, up front, and record the answer in the task handoff (`sb task prepare`) or in the chat.
- Without a structured question tool, ask in plain text with numbered options and wait. In an unattended run with nobody to answer, do not guess: mark the task `--needs-user` and record what is missing.
- Record durable decisions with `sb decide "..."` and keep the current state with `sb context --set`.
- Never copy dossier content into the repository.
<!-- secondbrain:end -->
