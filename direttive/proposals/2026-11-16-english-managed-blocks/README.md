# Proposal: English text for the managed block fallbacks (#670)

Status: awaiting approval. Not an active directive; nothing here is applied until `scripts/approve-revision.ps1 -Preview` and explicit approval.

## Problem
Product content is English, but the managed repository-block fallback in `scripts/SecondBrain.Portable.psm1` (`New-SBPortableRepositoryBody`, `$fallback`) is Italian. It is written into `AGENTS.md` blocks when `direttive/AGENTS.repo.managed.md` is missing. Managed blocks change only through their generators and an approved revision, so #670 did not edit it.

## Text to change (seven lines, in order)
1. `SecondBrain: optional integration of knowledge and common directives.`
2. `Resolve SECONDBRAIN_HOME from the workstation user environment; no personal path is kept in this repository.`
3. `If the private clone is unavailable, continue with the local technical instructions and report the integration as not configured; do not create substitute memories or stubs.`
4. `From the SecondBrain clone use scripts/prompts.ps1 -Context -RepositoryPath <current-checkout> to resolve the dossier paths and its index.md.`
5. `Load the startup context with scripts/knowledge.ps1 -Startup (or the MCP tool get_startup_context): index, slim context, essential memory and the relevant task projection; detail and history only when needed.`
6. `Private memories, internal trackers, backups and operational output live in SecondBrain. Keep code, guides and publishable assets here.`
7. `The directives do not authorize commits, pushes, deletions of artifacts or implicit application tasks.`

## Counterexamples and limits
- Repositories whose block hashes came from the Italian fallback show drift until re-synced; run `secondbrain.ps1 -Sync` after approval.
- The Core module was checked: no further Italian managed block text beyond the fallback above.
