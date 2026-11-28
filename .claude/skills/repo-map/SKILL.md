---
name: repo-map
description: Orients the agent in the repository layout. Use at the start of a task, or when unsure where code, tests or documentation live.
---

# Repository map

- `cli/`: the `sb` crate (Rust). `src/` holds one module per area (`run`, `start`, `prepare`, `check`, `mcp`, `sync`, `task`, `store`...), `tests/` the integration tests (`check`, `doctor`, `flow`, `run`), `README.md` the workflow and MCP guide.
- `.github/`: CI (`workflows/cli.yml`), release builds (`workflows/release.yml`, `scripts/third_party_licenses.py`), Dependabot, CODEOWNERS, issue and pull request templates.
- `.claude/skills/` and `.agents/skills/`: agent skills, two identical copies.
- Root: `COMMANDS.md` (all CLI commands and MCP tools), `README.md`, `AGENTS.md`, `CHANGELOG.md`, `VERSION`, `CREDITS.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `LICENSE`.

- Prefer existing patterns in the neighbouring files over new ones.
- Update this skill when the layout changes.
