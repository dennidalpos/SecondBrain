---
name: repo-map
description: Orients the agent in the repository layout. Use at the start of a task, or when unsure where code, tests or documentation live.
---

# Repository map

Use this map to find where things live before searching broadly.

Top-level folders (detected, may be incomplete):
- `.github/`
- `app/`
- `config/`
- `direttive/`
- `docs/`
- `repos/` (one dossier per managed repository; contents ignored by Git)
- `scripts/`
- `shared/` (shared references: sources, architecture, radar, troubleshooting)
- `workstation/` (governance, workstation and directive dossiers; contents ignored by Git)

- Read the folder's own README or instructions before editing inside it.
- Prefer existing patterns in the neighbouring files over new ones.
- Update this skill when the layout changes.
