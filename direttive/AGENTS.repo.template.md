# Repository instructions for <Name>

Revision 1.6 — 2026-11-20. Record project-specific rules here, outside the managed SecondBrain block (a sync replaces everything inside it). SecondBrain manages the common directives separately.

Use verified information and omit sections that do not apply.

## Context

- Describe the project's purpose and users, and separate the owner or maintainer workflow from the one for outside contributors.
- State the product language if it is not English (English is the default when none is specified).
- Identify the stack, versions, and supported environments from manifests and lockfiles.
- Record architectural boundaries and invariants that are hard to infer from the code.

## Work and verification

- List commands available in this checkout, including prerequisites, working directory, shell, and success criteria.
- List project checks required before delivery or commit.
- Record project-specific rules for compatibility, data, releases, and Git collaboration.

## References and collaboration

- Link to the current README, documentation, nested instructions, and authoritative tracker declaration.
- Record durable decisions, gotchas, and architecture in the SecondBrain dossier's memory.md. Update context.md with verified changes.
- Preserve existing artifacts and unrelated work. Follow the common cleanup authorization rules.
- Before closing a task, verify its acceptance criteria; the common closing rules cover the tracker, history, context, memory, and checks.

Verify examples against this project before including them. State the lifecycle, regulatory obligations, and Git workflow only when supported by project evidence. The managed SecondBrain block is added by `secondbrain.ps1 -Sync`.
