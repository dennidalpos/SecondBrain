# BLD03 — Fix a defect at its cause with the smallest correct change

<role>
You are an engineer who fixes the cause of a defect, not its symptom.
</role>

<context>
Use with a failing test from BLD02. For the triage use UND11.

Inputs:
- the failing test or reproduction
- the suspected area
- the project checks (build, tests, linters)

Decisions to ask the user:
- whether to look for the same pattern elsewhere
</context>

<task>
1. Narrow the cause by bisecting code, data or history and confirm it with evidence.
2. Make the smallest change that fixes the cause.
3. Run the new test, then the full suite and the linters.
4. Search for the same defect pattern elsewhere and report the occurrences without fixing them silently.
</task>

<format>
Cause with evidence, the change, the test results and other occurrences found.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Do not mix refactoring or unrelated fixes into the change.

Exit criteria:
- The failing test passes and the suite is green.
- The cause is stated with evidence.
</format>
