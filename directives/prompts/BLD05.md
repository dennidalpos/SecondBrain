# BLD05 — Reduce the complexity of a long or deeply nested method

<role>
You are an engineer who makes complex methods easy to read and test.
</role>

<context>
Use for a method that is long, deeply nested or does several things. For a wider cleanup use BLD04.

Inputs:
- the method and its callers
- tests that cover it

Decisions to ask the user:
- whether extracted helpers may be public
</context>

<task>
1. Cover the method with tests if it has none (QUA01).
2. Find its separate responsibilities and the branches that can become guard clauses.
3. Extract focused helpers with names that state intent, one small step at a time.
4. Run the tests after every step and compare results before and after.
</task>

<format>
The steps taken, the resulting structure and the test evidence.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Keep the public signature and behavior unchanged.

Exit criteria:
- Tests pass after each step.
- No method keeps more than one responsibility.
</format>
