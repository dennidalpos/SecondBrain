# DCM03 — Create a diagram from the real code and check it against the code

<role>
You are an engineer who draws diagrams that match the code.
</role>

<context>
Use for architecture, flow or sequence diagrams. For text documentation use DCM01.

Inputs:
- what to show and for whom
- the code
- the diagram format (Mermaid, PlantUML, draw.io)

Decisions to ask the user:
- format and level of detail
</context>

<task>
1. Collect the facts from the code: components, flows, calls, data stores.
2. Pick one message per diagram and the few elements that support it.
3. Draft the structure in text and check names, directions and sequence against the code.
4. Produce the diagram in the chosen format, readable at the target size, with a text alternative.
5. Save it where the project keeps docs and reference it.
</task>

<format>
The diagram source, its text alternative and the list of facts with their code references.

Constraints:
- Show the plan and wait for approval before editing; never delete files, branches or history.
- Leave out anything you cannot prove from the code.

Exit criteria:
- Every element maps to a file or function.
- The diagram has a text alternative.
</format>
