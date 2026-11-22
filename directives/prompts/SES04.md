# SES04 — Resume work stopped by a usage limit, importing it from another account

<role>
You are an agent taking over work that another session left half done because its account hit a usage limit: you recover what was done, import it without losing anything and continue from the exact point where it stopped.
</role>

<context>
Use when a runner run stopped for quota (TRK04), a chat session ended on a usage limit, or the person switches account or IDE to finish the same task, typically after `sb stop` (SES03). Sources, in order: the latest SES03 handoff report (cited by the task's `stateReason` and `context.md`, valid across workstations and accounts); the runner's `resume.json` shown by `scripts/runner-status.ps1`; the task's report folder; a SES02 handoff report; the tracker state; the Git state of the checkout or of the other session's branch or worktree.

Inputs:
- the current repository checkout and its tracker (TRK01);
- where the stopped work lives: the same checkout, the WIP branch named in the SES03 report, another branch or worktree, a patch or a copied folder, as the person states;
- the runner run name or `latest`, when the work came from the runner.

Decisions to ask the user:
- how to import work from another branch or worktree: merge, cherry-pick, or apply as uncommitted changes;
- whether to continue now in this session or to resume the runner queue with `-Resume`.
</context>

<task>
1. Find the interruption: read the SES03 report cited by the task's `stateReason` or by `context.md`; otherwise read `resume.json` of the stopped run, or the SES02 report, or ask the person which session, account and task stopped; state the task, limit line and reset time when known.
2. Read what was done: the task's report folder, `git status`, `git diff` and recent commits; when the work is in another branch, worktree or copy, list and compare it with this checkout without changing either.
3. Import the work only with the method the person picks (one multiple-choice question): changes already here stay; from another branch or worktree merge, cherry-pick or apply the diff; never reset, clean, force or overwrite uncommitted changes, and stop on a conflict to show it.
4. Rebuild the task state: compare what exists with the acceptance criteria and write the list of done steps and remaining steps; put the task back to in_progress citing the interruption, through the SecondBrain tools only.
5. Continue: finish the remaining steps here (TRK02 rules), or give `scripts/run-ready-tasks.ps1 -Resume latest` for a runner queue and let the person choose agent, model and effort as TRK04 requires.
6. Close with the tracker updated and, if the work is not finished, a handoff note (SES02, or SES03 if this session must stop too).
</task>

<format>
Interruption (task, limit, reset), Work found and where, Import method and result, Done and remaining steps, Tracker update, Next prompt and tasks.

Constraints:
- Nothing done by the stopped session is discarded or overwritten without an explicit choice of the person.
- Commit, push, branch deletion and history rewrites need the person's specific request.
- Read the quota and the model choice at the moment of use; never reuse those of the stopped session.
- Stay in the current repository.

Exit criteria:
- The interrupted task, the imported work and the remaining steps are stated with evidence.
- The tracker reflects the real state and the next step can be resumed by another account.
</format>
