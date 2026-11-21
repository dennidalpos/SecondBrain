# IDE adapters and live qualification

SecondBrain distinguishes file configuration, installed client, profile, environment, account and actual loaded instructions. Evidence on one surface does not certify the others. SYS01 guides verification after setup and after login/profile changes.

## Inspect the map

~~~powershell
pwsh -NoProfile -File scripts/ide-map.ps1 -Verify
~~~

The verifier compares selected instruction files with the expected generated global block. Manual integrations require an observation receipt. Exit codes are 0 aligned/verified within scope, 1 pending alignment/qualification or missing map, 2 error.

## Guided verification

~~~powershell
pwsh -NoProfile -File scripts/ide-map.ps1 -Guide
~~~

`-Guide` is read-only and exits like `-Verify`. It checks automatically everything that is deterministic: the managed `secondbrain:global` block of each file-based integration against the generated text (aligned, out of date with both revisions, no block, missing file), the declared account text of each manual integration against the approved hash (out of date with both revisions), and the observation receipts. For each integration that still needs a person it prints the steps for that client, and once at the end the exact text to copy: a file block that is out of date is fixed with `secondbrain.ps1 -Sync`; an account text is pasted where the client keeps its custom instructions (the location is named for the known clients and depends on the version) and then declared with the printed `-Setup -IdeAccount` command, which carries the revision and hash so nothing is typed by hand; every integration then needs a new-session observation (open a new session, check the account, ask it to quote the revision line) recorded with `ide-observation.ps1`. What cannot be derived from the files, namely the active account, the loaded instructions and the write scope, is never marked verified by the guide.

The host map is generated from active bindings/discovery. Do not manually mark a client/account verified. A file can be aligned while account/loading remains unverified; record both outcomes.

## Surface-specific workflow

| Surface | Required evidence |
|---|---|
| Repository instructions | Correct AGENTS source and generated adapter pointers |
| User file | Actual selected configuration root and approved block hash |
| Project/profile | Workspace/profile identity and the configuration really used |
| Account setting | User-declared account alias and manually observed instruction text |
| Running client | New-session observation with revision/hash and evidence |
| Write capability | Actual permitted roots and observed command/denial, not a guessed sandbox model |

No credential/authentication archive is read to discover accounts. Multiple accounts/config roots need distinct declared entries; login is manual. Treat changed account/profile/environment identity as ide-context-changed and requalify it.

## File and manual integrations

Claude-family, Codex and Antigravity have supported file/registration paths in the implementation. Additional adapters can be discovered without being live-qualified. A running executable or directory is evidence of presence only.

Manual account surfaces, including app settings and integrations without an instruction file, require the user to apply the generated text and provide a real observation. Do not infer account instructions from a generic help page or another profile.

The repository common source is AGENTS.md. Sync manages CLAUDE.md/GEMINI.md import pointers for adapters needing them; other clients may require their own supported configuration. Preserve unrelated content and report conflicts instead of editing generated blocks by hand.

## MCP is a separate check

Pair preview inspects target/scope/path; Apply changes selected configuration after authorization. Codex/Claude Code user registration and workspace configuration are different scopes. A successful stdio handshake proves protocol behavior in that run, not live instruction loading or account state.

Use [MCP setup](mcp-setup.md) for target/permission/package details. Restart only the intended owned client session when configuration changes require it.

## Account alias for manual surfaces

A manual surface (for example the Claude account instructions) is never registered anonymously: its alias says which account the text belongs to, and it is the key of the integration id. The alias is the Claude account id or a pseudonym (2-64 characters: letters, digits, `.`, `_`, `-`; an email address is rejected). SecondBrain cannot read the active account (it never opens authentication stores), so the alias is declared:

- `-IdeAccount "<ide>|<alias>|..."` declares it explicitly.
- `-Interactive` asks for it, offering the alias already registered for the same surface as the default.
- A non-interactive selection by name (`-Ides`, `-AllIdes`) reuses the single alias already registered for that surface and stops with an error when there is none or when several exist.
- `-Check` reports `account-alias-missing` for a manual entry registered without alias.

## Account text from a receipt (#188)

Typed `revision=` and `hash=` values can contain typos. `-IdeAccount "<ide>|<alias>|observation=<path>"` reads them instead from a JSON receipt under `.runtime` (manual IDE surfaces only; not combinable with `revision=`/`hash=`):

    {"schemaVersion":1,"ideId":"<optional id>","accountAlias":"<optional alias>","observedRevision":"1.0","observedHash":"<64 hex sha256 of the account text>"}

The path must be inside `.runtime`; unknown fields, a non-numeric revision, a hash that is not 64 hex characters, an `ideId` or `accountAlias` that differs from the entry, a missing or malformed file are rejected before the preview. The registered entry records the receipt file hash in its note, and the setup preview shows revision and hash before confirmation. Loading in a chat remains unverified (see delegated verification). Verified on fixtures for the reader (`-Only trace`) and by a read-only `-Setup -PreviewOnly` run with a valid receipt (revision and hash appear in `ideBindings`), a path outside `.runtime` and a `revision=` mix (both rejected); no applied activation was run.

## Delegated verification (#155)

What the filesystem cannot show (active account, loading in a new session) is delegated to an agent already installed. SecondBrain builds the package; the agent observes and produces the receipt; SecondBrain validates and registers it. Nothing here logs in, reads authentication stores or edits IDE files.

    pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Package -IdeId <id>
    pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Register -IdeId <id> -InputPath <receipt.json>
    pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Register -IdeId <id> -InputPath <receipt.json> -PreviewSha256 <previewed hash> -Apply
    pwsh -NoProfile -File scripts/ide-observation.ps1 -Operation Prune [-Apply]
    pwsh -NoProfile -File scripts/ide-map.ps1 -Verify -ObservationPath <repo>/.runtime/hosts/<host>/ide-observations.json

- Package (read-only) prints the new-session steps, the expected revision and hash, the account alias and an exact receipt template. One account is one integration id, so two accounts of the same IDE get two packages.
- Register validates the receipt with the same predicate as `ide-map.ps1 -Verify` (host, profile, account alias, text hash, freshness of 15 minutes, evidence hash inside `.runtime`) and rejects unknown fields. The preview writes nothing; Apply requires the previewed hash and rejects a missing or different one, so a receipt changed after review is never stored. A new receipt replaces only the same id.
- Prune removes receipts of integrations no longer in the map, for example after `secondbrain.ps1 -Setup -Unbind <id>`.
- Limit: the receipt is declared by the observing agent and proven only by the evidence hash. Verified on synthetic fixtures (two alternating accounts, `-Only trace`); live observations stay in #153/#180.

## Observation receipts and limits

ObservationPath supplies a schema-validated receipt bound to the intended host/client/account/profile, expected text hash and real evidence. Freshness/current context and source revision matter. A fabricated receipt or a fixture cannot qualify a live client.

Write access is also observed, not assumed. core.write.denied/CLI exit 4 differs from lock contention (exit 3). Preserve original diagnostics and recovery markers; do not automatically widen writable roots or modify private IDE instructions as a shortcut.

Sources in local fixtures demonstrate parser/adaptor behavior. They do not prove every installed client version, GUI permission dialog, account setting, native collector or multi-host filesystem condition. Report unavailable observations as pending.

See [safe writes](safety-backups.md), [access](access.md), [memory cycle](memory-cycle.md) and [operations](operations.md).

## Reviewed MCP writes

The [write support matrix](mcp-writes.md#client-support-and-approval-matrix) separates the synthetic stdio contract from real client qualification. Local receipts bind one request to its user, workstation and checkout. Neither existing preauthorization scope includes the new tools. Personal IDE settings are unchanged.

## Single-turn memory permissions

Memory collectors use the explicit [Permit CLI receipt](memory-cycle.md#explicit-single-turn-cli-receipt). Codex, Claude Code and Antigravity share receipt validation and the Stop bridge, with native boundaries checked on synthetic fixtures. Those fixtures do not qualify installed client versions. If the client does not expose the required request and turn identifiers, keep the normalized-envelope fallback. Existing live receipts are revision-bound; a changed module requires new qualification.

| Client | Native boundary checked on fixture | Version claim |
|---|---|---|
| Codex | session_id, turn_id, transcript_path, exact human text blocks; Stop final text deduplication | clientVersion="fixture"; no new installed-version qualification |
| Claude Code | session_id, transcript_path, last human UUID and exact content | clientVersion="fixture"; no new installed-version qualification |
| Antigravity | conversationId, executionNum, transcriptPath, exact userMessage, declared terminationReason | clientVersion="fixture"; no new installed-version qualification |

The CLI stores the version asserted by its caller. It does not discover or certify that version. Error/interruption fields supplied by a producer can be preserved; missing native delivery or missing termination fields remain unknown. Physical crashes and real client interruptions remain in #352.