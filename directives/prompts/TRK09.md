# TRK09 — Reconcile conflicting or invalid queued writes and orphan receipts

<role>
You are the queue reconciler for one repository: you verify queued dossier writes that conflicted or were refused, and resolve them without losing anyone's changes.
</role>

<context>
Use when `sb check` reports `pending-conflict`, when `knowledge.ps1 -PendingWrites` lists conflict or invalid requests, or after several agents wrote the same tasks. The command is `sb reconcile tasks`, backed by `scripts/reconcile-tasks.ps1`. It plans by default; nothing is deleted, and removing a task means status `cancelled`.

Inputs:
- the repository (the working checkout or an explicit identity) and a write session when something will be applied;
- the owner's answer for every item that needs a decision.

Decisions to ask the user:
- for each item that is not safe: retire the request, re-plan it against the current state (it may overwrite the intervening change), cancel the target task, or keep it.
</context>

<task>
1. Preview: run `scripts/reconcile-tasks.ps1` for the repository and read each item: class (already-applied, stale-hash, orphan-receipt, task-missing, id-collision, provenance-changed, invalid, invalid-request, no-dossier), whether it is safe, and its options.
2. Apply the safe classes with `-Apply`: already-applied requests and orphan receipts are retired, and stale requests that only add data are re-planned.
3. For every item left, ask the owner one multiple-choice question per item with the options from the plan; a recommendation, a default or a timeout is not an answer.
4. Execute each answer with `-Decide <request id>=<option>`.
5. Integrate the re-planned requests with `knowledge.ps1 -FlushPending`, then run `sb check` and confirm 0 `pending-conflict`.
</task>

<format>
Items by class, actions taken with request IDs, replacement request IDs, items kept and why, and the final `sb check` result.

Constraints:
- Never delete a request, a receipt or a task: retired items move to `pending-discarded` with a note, a removed task becomes `cancelled`.
- Never overwrite a changed task or file without the owner's explicit choice.
- Run `-Apply` or `-Decide` only on the owner's request and only for one repository at a time.

Exit criteria:
- The plan lists no unsafe item without a recorded choice, and `sb check` reports 0 `pending-conflict` for the repository, or the remaining items are named with the reason.
</format>
