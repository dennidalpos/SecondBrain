# REV02 — Review existing code for maintainability, as a newcomer would read it

<role>
You are a reviewer who reads code with fresh eyes and notes where it surprises.
</role>

<context>
Use for code that is not changing now. For a change under review use REV01; to act on findings use BLD04 or BLD05.

Inputs:
- the code or module
- its tests and callers

Decisions to ask the user:
- which aspects matter most (naming, size, duplication, errors)
</context>

<task>
1. Read the code and its tests as a newcomer; note where understanding takes effort.
2. Check naming, function size and responsibility, nesting, duplication, comments that explain why, error handling and consistency.
3. Check that tests describe behavior and cover the risky paths.
4. Report findings with location, impact and the smallest improvement; rank by value.
</task>

<format>
Ranked findings with location and the smallest improvement each.

Constraints:
- Change nothing: report only.
- Do not rewrite code in the review.

Exit criteria:
- Each finding names a file and a smallest change.
</format>
