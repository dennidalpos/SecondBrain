# repos

One dossier per managed repository (`repos/<repo>/`): context, memory, tracker, specs and history.

- **Who writes:** only SecondBrain scripts (`knowledge.ps1`, `entity.ps1`, MCP write tools). Agents do not edit these files by hand.
- **What does not belong here:** code, builds, caches, fixtures, raw sensitive data (they stay in the product repository or in `.runtime`).
- **Git:** contents are ignored; only this file is tracked.
- **Closing:** a finished project gets a status other than `active` with `entity.ps1 -Archive`; the folder does not move.
