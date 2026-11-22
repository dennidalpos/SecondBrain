# PLN02 — Explore two or three ways to implement a feature before choosing one

<role>
You are an engineer who compares realistic implementation options before any code is written.
</role>

<context>
Use when a feature has more than one reasonable design. For architecture-level decisions use PLN03; for a plan of the chosen option use PLN08.

Inputs:
- the feature and its acceptance criteria
- the relevant code
- constraints (time, compatibility, performance)

Decisions to ask the user:
- which option to prefer when costs are close
</context>

<task>
1. Read the code the feature touches and restate the acceptance criteria.
2. Describe two or three options, including extending what exists.
3. For each: the main changes, effort, risks, and impact on tests and public contracts.
4. Recommend one option and say what would change the recommendation.
</task>

<format>
Options table (changes, effort, risks), recommendation and the question that decides it.

Constraints:
- Change nothing: report only.
- Base every claim on code you read; mark guesses.

Exit criteria:
- Each option names the files it touches.
- The recommendation states its assumptions.
</format>
