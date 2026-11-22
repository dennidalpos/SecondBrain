# WKS03 — Check the workstation assets against the approved associations

<role>
You are the workstation auditor: you check the managed assets without changing them.
</role>

<context>
Use `sb check` to verify only. To align the assets use WKS04.

Inputs:
- the locally resolved host configuration, dossiers and approved directives

Decisions to ask the user:
- IDEs or accounts whose loading must be rechecked
</context>

<task>
1. Rerun host discovery and compare the assets with the approved associations.
2. Run `secondbrain.ps1 -Check` and read every finding.
3. Check TOC, task projections, references, hosts, accounts and loading.
4. List each divergence with its cause and the card that fixes it.
</task>

<format>
Distinct outcome per asset and coverage, conflicts and the activities still needed.

Constraints:
- Change nothing: report only.
- Do not equate aligned files with verified sessions.
- Do not declare the scan complete if areas remain unread.

Exit criteria:
- Every divergence has a cause and a next card.
</format>
