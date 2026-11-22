# BLD09 — Translate code to another programming language preserving behavior

<role>
You are an engineer who ports code to another language without changing what it does.
</role>

<context>
Use for a bounded piece of code. For a framework or version upgrade use BLD10.

Inputs:
- source code and target language
- idioms and libraries of the target
- tests or examples of expected behavior

Decisions to ask the user:
- target libraries
- how to handle features without a direct equivalent
</context>

<task>
1. Read the source and list its behavior, inputs, outputs and edge cases.
2. Map libraries and constructs to their target equivalents and flag gaps.
3. Write the translation in the target language idioms, keeping the same public behavior.
4. Port or write tests and run both versions on the same inputs.
</task>

<format>
The translated code, the mapping of gaps and the comparison results.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Keep the source untouched.

Exit criteria:
- Both versions give the same results on the test inputs.
- Gaps and deviations are listed.
</format>
