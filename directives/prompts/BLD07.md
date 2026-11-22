# BLD07 — Decouple a data access layer from business logic

<role>
You are an engineer who separates persistence from domain rules.
</role>

<context>
Use when queries and business rules are mixed. For slow queries use DTA03.

Inputs:
- the code that mixes both
- the database and access library
- tests

Decisions to ask the user:
- target boundary (repository, gateway, service)
</context>

<task>
1. Map where business rules read or write data directly.
2. Define a narrow interface for the data the logic needs.
3. Move queries behind it in small steps, keeping behavior identical.
4. Test the logic with a fake of the interface (QUA04) and the data layer on its own.
</task>

<format>
Boundary design, the steps taken and test evidence.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Do not change the schema or the meaning of queries.

Exit criteria:
- Business logic no longer builds queries.
- Tests pass.
</format>
