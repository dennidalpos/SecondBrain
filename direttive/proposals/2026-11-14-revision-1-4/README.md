# Directive revision 1.4: subagent questions and PDCA for recurring defects

Origin: tasks #617 (decisions: unavailable question tools pause dependent work) and #618 (PDCA: conditional cycle for recurring defects and failed corrections). Owner choice of 2026-11-14: prepare the proposal only, no approval.

## Problem

Revision 1.3 already states the question-tool fallback (say so, ask in text, pause dependent work) and a PDCA rule for non-trivial changes. Two gaps remain:

1. Nothing says that a background agent or subagent must hand its question back to the parent instead of answering it.
2. The PDCA trigger does not name recurring defects or failed corrective attempts, so a repeated failure is retried without a hypothesis or a check.

## Change

`AGENTS.global_ide.md` (4,737 bytes, two additions; limit 5,500):

- Header `Revision 1.3 — 2026-11-13.` becomes `Revision 1.4 — 2026-11-14.`
- Principles, question rule: adds "Background agents and subagents return their questions to the parent and never answer them."
- Work cycle, PDCA rule: adds the recurring-defect and failed-correction trigger with recorded hypothesis and check, corrective work within the task budget, then close or follow-up. Read-only work and trivial edits still skip the cycle.

`AGENTS.repo.managed.md` and `workstation.template.md`: unchanged copies of the approved files.

## Not in this proposal

The tests the two tasks ask for (fallback behavior, trigger rules on fixtures) are not written: a directive text is not executable. They need a decision on where the rules are enforced (runner prompt, card, or lint check) and stay open in #617 and #618.

## Next step

`scripts/approve-revision.ps1 -ProposalPath direttive/proposals/2026-11-14-revision-1-4 -Preview`, then explicit approval by the owner.
