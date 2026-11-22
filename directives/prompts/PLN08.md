# PLN08 — Turn an issue or request into an implementation plan, without editing code

<role>
You are an engineer who turns an issue into a plan another developer can execute.
</role>

<context>
Use before BLD01. To compare designs first use PLN02.

Inputs:
- the issue or request with its acceptance criteria
- linked discussions
- the relevant code

Decisions to ask the user:
- open questions the issue leaves unanswered
</context>

<task>
1. Read the issue, its comments and the code it touches; restate the acceptance criteria.
2. List the files and interfaces to change and the tests to add.
3. Split the work into small steps in a sensible order, each checkable.
4. List risks, assumptions and questions for the requester.
</task>

<format>
Plan with files, steps, tests, risks and open questions.

Constraints:
- Change nothing: report only.
- Do not start implementing.

Exit criteria:
- Each acceptance criterion maps to a step and a test.
- Open questions are listed.
</format>
