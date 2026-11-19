# Directive revision 1.5: portable core, role-based references, user-file safety

Origin: task #728 (`para.ps1` became `entity.ps1` after the flat layout), the critical audit of revision 1.4 for the project's use case and for people who download it, and task #733 (a sync deleted project text written inside the managed block).

## Change

`AGENTS.global_ide.md`
- Header `Revision 1.5 — 2026-11-19.`
- Portable core first; the SecondBrain section moves last and opens with an applicability line (SECONDBRAIN_HOME set or a SecondBrain block present). If the checkout or dossier is unreachable the agent says so, continues from the repository files and invents nothing.
- Tools are named by role plus `sb` commands, so a script rename needs no revision. The single startup entry point (`scripts/knowledge.ps1 -Startup`, MCP `get_startup_context`) stays exact: a Quick check requires it in the user-scope text so the context loads without files in the repository (#484).
- Language: follow the language the user or the project specifies; English is the default when none is specified.
- Contestable rules relaxed or scoped:
  - commits, pushes, publication and messages: the user's specific authorization, or a standing permission the user gave for the project;
  - delegation: allowed when the user, task or workflow asks (no longer "only");
  - Plan-Do-Check-Act: in proportion to the size of the change;
  - version change: the changelog is updated only when the project keeps one;
  - the 1,500-character rule for context.md becomes "keep each section short" (nothing in the code enforces the number);
  - the prompt-card ID rule leaves the common text: it is a maintainer rule of this repository and stays in its `AGENTS.md`.
- New: user files are the user's. Change one only inside a tool-marked managed block, or as the user asked, and report a conflict instead of overwriting.
- "substantial", "task budget" and the version-change trigger are defined.

`AGENTS.repo.managed.md`
- The block is generated: project rules go outside it (task #733). If the checkout is unreachable the agent continues from the repository files. Tool names become roles.

`workstation.template.md`
- `scripts/access.ps1` becomes "the access tool".
- New bullet: run `sb check` (read-only) before `sb sync`; run `sb sync` or `sb setup` only when the user asks; instruction files change only inside managed blocks; a hand-edited block or a tracked file with uncommitted changes is a conflict, left untouched and shown to the user. This describes the current behavior of `Set-SBManagedContent` and the tracked-dirty guard; nothing in the code changes.

## Outside the approval hashes

- `AGENTS.repo.template.md`: revision label, maintainer/contributor split, language line, no repeated closing rule.
- Repository `AGENTS.md`: language default instead of an absolute rule; the pull-request and push-policy sections are removed (subjective, project-specific). The common rule on commit and push authorization still applies.

## Cost

- Every managed block and the workstation block change, so `sb sync` rewrites the managed blocks of the bound repositories once; later script renames do not.

## Counterexamples considered

- A repository without SecondBrain: the core applies unchanged and the SecondBrain section is skipped.
- A user who asks for Italian product text: the language rule follows the request.
- A user with their own CLAUDE.md or AGENTS.md: only the marked block changes; a hand-edited block is a conflict, never overwritten.

## Next step

Owner review with `scripts/approve-revision.ps1 -ProposalPath direttive/proposals/2026-11-18-revision-1-5 -Preview`, then explicit approval. After approval: `sb sync`, then update the account instruction texts (claude.ai manual text and any profile copy) to the same wording and register the observation receipt (tasks #639, #703, #250).
