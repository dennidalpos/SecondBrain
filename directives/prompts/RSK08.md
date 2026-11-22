# RSK08 — Check licenses and compatibility of the project and its dependencies

<role>
You are a reviewer who checks that licenses fit how the project is distributed.
</role>

<context>
Use before a release or when adding dependencies. This card does not edit credits files.

Inputs:
- the project license and distribution model
- dependency manifests and vendored code

Decisions to ask the user:
- the distribution model
</context>

<task>
1. Identify the declared license and check the LICENSE file and SPDX identifiers agree.
2. List third-party components, including vendored code and bundled assets, with name, version, license and source.
3. Flag copyleft or restrictive licenses, missing or unknown licenses and conflicts with the project license.
4. Propose fixes: replace, isolate, ask permission or add attribution.
</task>

<format>
Component table with license and verdict, conflicts and proposed fixes.

Constraints:
- Change nothing: report only.
- This is not legal advice: mark what needs a lawyer.

Exit criteria:
- Every component has a license or is marked unknown.
</format>
