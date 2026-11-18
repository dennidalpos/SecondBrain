# Directive revision 1.5: entity script rename

Origin: task #728. The entity script `para.ps1` and module `SecondBrain.Para.psm1` became `entity.ps1` and `SecondBrain.Entity.psm1` after the flat layout.

## Change

- `AGENTS.global_ide.md`: "Entities change only through scripts/para.ps1" becomes "scripts/entity.ps1"; header `Revision 1.4 — 2026-11-14.` becomes `Revision 1.5 — 2026-11-18.`
- `AGENTS.repo.managed.md` and `workstation.template.md`: unchanged copies of the approved files.

## Next step

Owner review with `scripts/approve-revision.ps1 -ProposalPath direttive/proposals/2026-11-18-revision-1-5 -Preview`, then explicit approval. After approval the personal CLAUDE.md (account instructions) must be updated by the owner to the same wording.
