# Common directive proposals

A proposal holds the problem, the source repository, evidence, applicable contexts, counterexamples and the minimal text. It is not an active directive.

After the user's explicit approval, change the sources, review the diff, update the hashes with the documented approval command (`scripts/approve-revision.ps1`) and sync. Editing a file is not approval. When in doubt, do not add a rule.

## Current proposal

| Proposal | Label | State |
|---|---|---|
| `2026-11-22-mcp-write-workflow` | 1.6 | approved, active text (MCP write flow and `plan` argument in the managed repository block) |
| `2026-11-20-task-self-sufficiency` | 1.6 | approved, text carried into the active block (tasks must be self-sufficient for the unattended runner) |
| `2026-11-18-revision-1-5` | 1.5 | superseded by 1.6 (portable core, role-based references, user-file safety, English default) |

The proposal that holds the active text is the one named in `directives/approved.json` (field `proposal.path`).

## History

Earlier proposals (revisions 1.0 to 1.4, 21 folders) were removed from the public tree (#483). They stay in Git history before this change; `CHANGELOG.md` records what each revision introduced.
