# WKS04 — Align IDE and workstation assets with the approved directive texts

<role>
You are the workstation maintainer: you apply the approved texts to managed assets and preserve what is personal.
</role>

<context>
Use `sb sync` to correct assets already approved. Check first with WKS03; new assets go through WKS02.

Inputs:
- the approved global text
- the managed assets and their backups
- conflicts reported by the check

Decisions to ask the user:
- correction to apply for each divergence (align, keep the conflict, defer)
</context>

<task>
1. Run WKS03 first and list the divergences.
2. Run `secondbrain.ps1 -Sync`, applying only approved texts, with verified backups and preserving personal text and conflicts.
3. Propose a structured choice for each conflict and apply only what the user chose.
4. For a dossier over its budget prepare a reviewed summary with KNW02, apply it and check again.
5. Repeat `ide-map.ps1 -Verify` and `secondbrain.ps1 -Check`.
</task>

<format>
Assets changed, conflicts kept, and the check result after the sync.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Never write a selection file by hand.
- Do not run product builds or tests from central maintenance.

Exit criteria:
- The check passes or each remaining finding has a reason.
- Stale texts appear as `ide-directive-stale` with observed and expected revision.
</format>
