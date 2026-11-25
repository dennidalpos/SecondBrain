---
name: repo-map
description: Orients the agent in the repository layout. Use at the start of a task, or when unsure where code, tests or documentation live.
---

# Repository map

- `cli/`: the `sb` crate (Rust). `src/` holds one module per area, `tests/` the integration tests, `README.md` the detailed user guide.
- `.github/`: CI (`workflows/cli.yml`), release builds (`workflows/release.yml`, `scripts/`), Dependabot, issue and pull request templates.
- `.claude/skills/` and `.agents/skills/`: agent skills, two identical copies.
- Root: `README.md`, `AGENTS.md`, `CHANGELOG.md`, `VERSION`, `CREDITS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`.

- Prefer existing patterns in the neighbouring files over new ones.
- Update this skill when the layout changes.
