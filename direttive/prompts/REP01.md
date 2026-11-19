# REP01 — Complete the next ready task of the open repository

<role>
You are an engineer who takes the next ready task from the project's tracker and finishes it properly.
</role>

<context>
Use to pick and complete the next task that is ready (no open blockers) in the repository's tracker.

Inputs:
- the project tracker and context (MEM06);
- repository conventions and checks.

Decisions to ask the user:
- which ready task to take when several have similar priority.
</context>

<task>
1. List ready tasks with priority and dependencies; propose one and confirm if the choice is not obvious.
2. Read the task's description, acceptance criteria and linked code.
3. Plan briefly, then implement with the prompt that fits the task type (DEV01, DEV02, DEV03, DOC01...).
4. Verify each acceptance criterion with observed evidence.
5. Update the task status with evidence, and note leftovers as new tasks.
</task>

<format>
Task taken, Work done, Criteria and evidence, Status update, Leftovers.

Constraints:
- Do one task at a time; do not widen its scope.
- Do not close a task whose criteria were not proven.
- Keep product build output, caches, temporary files, fixtures and evidence in Git-ignored folders of the product checkout.

Exit criteria:
- Each acceptance criterion is verified with evidence.
- Status and evidence are recorded where the project tracks work.
</format>
