# Repository instructions: SecondBrain

<!-- secondbrain:repository:begin -->
Common directives applied: revision **1.6** — 2026-11-20. <!-- secondbrain:source global=0A70848B8CBBE1939BDB240F37280AB3594914B41E4152F8543A554F04FEF0FF workstation=2B4198D3D9F66B2EC4AD159DC7889F6C21AD64C5E025B99005D26122D6E5AEDB -->
## SecondBrain

Repository knowledge lives in the SecondBrain dossier; code, guides, and publishable assets stay here. This block is generated: write project rules outside it, because a sync replaces everything inside.

- Load the slim startup with MCP get_startup_context or the startup mode of the SecondBrain knowledge tool, and follow its references for detail. If the checkout is unreachable, report the dossier as unavailable and continue from the repository files.
- Write only to this repository's dossier `repos/<repo>/`, only through SecondBrain scripts or MCP write tools. Work folders come from the work tool's init mode; sessions, retention, and cleanup rules load from `sb prompt`.
- Commits, pushes, deletions, and publication require specific authorization.
- Every task you create or update must run unattended. For an autonomous task, ask the user for what `needsInfo` or the readiness result reports missing (files in scope, checks to run, acceptance, inputs, decisions) with the client's structured question tool; skip it only when the user says otherwise, then set `execution` to `user_required`.
<!-- secondbrain:repository:end -->

## Setup
- Fresh clone or "install SecondBrain": follow `docs/inizia.md#install-with-one-prompt` (preflight, ask for the location, preview, `sb setup`); ask before every write.
- PowerShell 7.5+ and Git on Windows; nothing to install. Scripts are in `scripts/`, directive and prompt texts in `direttive/`, documentation in `docs/`.
- The clone is the SecondBrain root: `.runtime/` (Git-ignored) holds the workstation's configuration, sessions, fixtures and backups.

## Checks
- Quick and pure: `pwsh -NoProfile -File scripts/test-secondbrain.ps1 -Quick`; default: no options; full: `-Full`; one group: `-Only quick|workflows|trackers|audit2|trace|concurrency|shared|pending|sources|external-audit|git-environment|runtime|prompts|tracker-audit|mcp-writes|runner|ide|agents|lint|cleanclone|orchestrator-e2e` (`-Full` runs the extra suites, `tracker-audit` included, in parallel as separate processes; `-Sequential` runs them one at a time).
- Desktop app `app/orchestrator` (Tauri 2): `npm ci` and `npm run build` (TypeScript check and build), `cargo test --manifest-path src-tauri/Cargo.toml`; guide in `docs/orchestratore.md`.
- Prompts: `scripts/build-prompts.ps1` regenerates the indexes from the catalog and the cards; `-Check` reports drift. Never edit the `README*.md` files in `direttive/prompts/` by hand.
- `scripts/secondbrain.ps1 -Check` and `scripts/ide-map.ps1 -Verify` check directives, IDEs and dossiers.
- Test fixtures go in `.runtime/hosts/<host>/repos/tests-<hash>/fixture/`; ACL failures in `concurrency` depend on the environment, not on this repository.

## Code style
- PowerShell with `Set-StrictMode`; messages only through keys in `Add-SBMessages` (no `throw` or `Write-Host` with literal text); writes only with `Write-SBFile` and verified backups.
- Product text (messages, help, UI, docs, prompts, diagnostics) defaults to English unless the task or the user specifies another language. Existing `it` message entries, Italian cards and `*.it.md` pages are removed only through the English-only tasks (#580–#586) and the reviewed removal manifest; add Italian text only when asked or when a check still requires it. Some folder and file names are still Italian (`direttive/`, parts of `docs/`) until those tasks finish.
- Prompt assets follow `docs/riferimento/asset-contracts.md`: cards, workflows, agent definitions and user decisions keep immutable IDs; codes and keys are display names, renamed only with a catalog version and an alias and never reused. Scripts, the app, config and directives refer to cards by ID or role, never by code. Add or change cards with the catalog's card procedure (`sb prompt`).
- Common directives change only through a proposal in `direttive/proposals/`, `scripts/approve-revision.ps1 -Preview` and explicit approval; managed blocks change only through their generators. `VERSION` and `CHANGELOG.md` follow the version rule.

## Security
- No secrets, personal paths or account data in the repository; publication scans (`scripts/publication.ps1` or MCP `check_publication`) come before every push.
- `.runtime` cleanups and migrations (`scripts/cleanup.ps1 -Migrate`, `-Regenerable`) preview by default and need `-Apply` with an explicit `-Authorization`.
