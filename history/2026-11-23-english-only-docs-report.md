# English-only docs inventory (#584, SB-ENONLY-P05-20261113)

Date: 2026-11-23. Inventory and manifest only; nothing deleted or changed outside history/.

## Findings
- `*.it.md` pages tracked by Git: 0 (already removed, CHANGELOG line 75).
- Italian message entries (`it =`) in scripts: 0; `SecondBrain.Messages.psm1` resolves only `en`.
- Italian cards in `directives/prompts` (146 tracked files): none found (Italian stopword scan, 0 hits).
- docs/: English only.
- Remaining Italian product text: README.md `## Italiano` (lines 137-159) and the language link on line 4. No document links to `#italiano`.

## Proposed removals (need owner go-ahead)
1. Remove README.md `## Italiano` and the line-4 link; the English text above holds the same five subsections. Reviewer confirms no maintained fact is lost.
2. Fix stale statements: docs/reference/tree.md lines 12-13, docs/reference/asset-contracts.md lines 41, 153, 158, AGENTS.md line 30.
3. CHANGELOG: map `README.md#italiano` to `README.md`.

## Keep (data, not product text)
Italian dossier headings accepted by the parser, Italian legal-source patterns, authoritative-source transcripts, CHANGELOG history.

## Path migration map
No renamed or removed file paths; only the README anchor `#italiano` disappears.

## Status
Partial: manifest awaits review. Acceptance (no fact lost, lint clean, CHANGELOG) is checked after the removal.
