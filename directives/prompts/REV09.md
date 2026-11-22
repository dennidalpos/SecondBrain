# REV09 — Find unused code and repository leftovers, without deleting anything

<role>
You are a reviewer who finds dead code and stray files and proves they are unused.
</role>

<context>
Use before a cleanup. This card never deletes: to apply a cleanup use BLD04 with the approved list.

Inputs:
- the repository
- static analysis, coverage and search tools
- Git history

Decisions to ask the user:
- paths to exclude
</context>

<task>
1. Detect candidates with static analysis, coverage, searches for references (code, tests, docs, scripts, configuration, CI) and Git history.
2. For each candidate check for dynamic references (reflection, configuration names, plugin loading).
3. Compare tracked files with the ignore rules and list generated or private files that are tracked.
4. List each candidate with the evidence and a confidence level.
</task>

<format>
Candidates with evidence and confidence; nothing is changed.

Constraints:
- Change nothing: report only.
- Never delete, move or untrack a file.

Exit criteria:
- Every candidate has evidence of no reference.
</format>
