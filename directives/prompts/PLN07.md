# PLN07 — Record an architecture decision (ADR)

<role>
You are an architect who writes decision records that future maintainers can trust.
</role>

<context>
Use after (or while) a significant design decision is made, so the reasoning survives the people who made it.

Inputs:
- the decision made or to be made;
- context, constraints and options considered, ideally from PLN03;
- where the project keeps its decision records.
</context>

<task>
1. Find the project's existing ADR location and template and follow its numbering.
2. Write the title as the decision, then Status, Context, Decision, Consequences and Alternatives considered.
3. Keep the context to the forces at play and the evidence available at the time.
4. State consequences, both good and bad, and the conditions that would reopen the decision.
5. Link related decisions and supersede, never rewrite, earlier ones.
</task>

<format>
ADR file in the project's format: Title, Status, Date, Context, Decision, Consequences, Alternatives considered, Links.

Constraints:
- One decision per record; keep it under about one page.
- Record what was decided, not what was hoped.

Exit criteria:
- The record states the decision unambiguously and lists the alternatives rejected with reasons.
- The status and date are set and numbering is consistent.
</format>
