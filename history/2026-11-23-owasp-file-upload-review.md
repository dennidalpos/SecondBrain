# OWASP File Upload candidate review (task #755, 2026-11-23)

Source: `owasp-file-upload`, accepted version `20261027-af7d03c7c740eee2` (unchanged; `acceptedVersion` not touched).

## Collection (SYS02, approved by the owner 2026-11-22)
`scripts/sources.ps1 -Collect -SourceId owasp-file-upload` returned `status: unchanged`, `versionId: 20261120-77436177c9b43bc5`.
Upstream still serves the content of the candidate rejected on 2026-11-22 (fingerprint `77436177…57936C4`). No new version was created.

## Verification
- Revision: raw.githubusercontent.com `master`, no publication date (stays null); candidate sha256 `78FAC058…9536E7D`.
- Rights: unchanged, CC BY-SA 4.0, `public-reusable`, attribution to the OWASP Cheat Sheet Series contributors.
- Content diff vs accepted original: one line (101). The "leading periods / sequential periods" rule gains the sentence: "Character rules alone don't prevent traversal, so also check the final path as described in the Path Traversal Prevention Cheat Sheet." The change adds a cross-reference and does not weaken any control.
- Extracted text: missing. The candidate manifest records `converter-unavailable`; no Python environment with `markitdown==0.1.9` exists under the runtime root, and `-Collect` was run without `-PythonPath`. The existing version directory is not regenerated on `unchanged`, and deleting it was not authorized.

## Open
1. Provide the converter (install `scripts/source-requirements.txt` under the runtime sources Python) and obtain a candidate with a transcript. Because the candidate is rejected and the content is identical, this needs the owner to say how to re-open the version (new collection after upstream changes, or reverting the rejection).
2. Owner decision on accepting the candidate; only then rerun `sources.ps1 -Check`.

`sources.ps1 -Check` (exit 1): `owasp-file-upload` reports `verification-stale`; the same run reports `changed` for `nist-ssdf`, `verification-stale` for `ec-ai-framework`, and many `mapping-missing` issues, all outside this task.

## Rerun (2026-11-23, second session)

-Collect returned unchanged again (versionId 20261120-77436177c9b43bc5); no new version, no transcript (converter still missing). sources.ps1 -Check exit 1, outcome identical to the run above; acceptedVersion untouched. Acceptance stays with the owner.
