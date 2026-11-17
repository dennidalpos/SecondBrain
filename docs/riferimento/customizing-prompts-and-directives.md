# Customize prompts and common instructions

[Retained Italian source; use this English page for current behavior](customizing-prompts-and-directives.it.md)

Prompt cards, common instructions, deployment and live client loading have separate approval/verification boundaries. Use SYS11 for card/catalog changes and the common revision workflow for new shared prescriptions.

<a id="modifica-dei-prompt"></a>

## Prompt catalog

English cards live under direttive/prompts/<CODE>.md, with Italian counterparts under it/. Each active card has stable code/immutable ID, catalog metadata and XML-tagged role, context, inputs, procedure, constraints, exit_criteria and output_format. Include decisions only when meaningful choices are needed.

Composition joins the objective, verified repository/project context, card, operating rules and next steps. It does not execute a task or grant permissions. Category/mode describe the workflow; read-only audits do not mutate trackers.

~~~powershell
pwsh -NoProfile -File scripts/prompts.ps1 -Show -Prompt DOC01 -Language en
pwsh -NoProfile -File scripts/build-prompts.ps1 -Check
~~~

Prompt commands never write to the dossier. Generated README indexes are not manual edit targets. After an authorized catalog/card change, regenerate with build-prompts then validate both language cards/IDs/indexes. Stable codes are not reused after retirement/merger; numbering gaps are intentional.

<a id="modifica-delle-direttive"></a>
<a id="3-ciclo-di-approvazione-e-distribuzione-delle-direttive"></a>

## Common instruction changes

1. Prepare concrete proposed source text and rationale under direttive/proposals/.
2. Run approve-revision Preview with ProposalPath.
3. Present the exact text/diff and proposal hash for explicit user approval.
4. Apply only that approved hash/authorization using the approval script.
5. Sync approved generator sources, then Check and verify selected IDE loading.

~~~powershell
pwsh -NoProfile -File scripts/approve-revision.ps1 -ProposalPath $proposalPath -Preview
~~~

Do not fabricate Authorization/ExpectedProposalHash, edit approved.json by hand or alter a managed snapshot to bypass the generator. Approval hashes detect changed text; they do not replace user authorization.

Repository-specific managed text resides in the identity-resolved dossier and follows the same approval boundary. Changes outside managed blocks must respect the repository owner's instructions and preserve existing work.

<a id="2-integrazione-delle-direttive-nei-diversi-ide"></a>

## IDE and repository integration

AGENTS.md is the common repository source. Managed CLAUDE.md/GEMINI.md pointers import it where those adapters require them. User/account instructions, profile configuration, workspace files and actual loading are separate surfaces. Account-only settings need manual application and evidence; no authentication-store discovery or automated login is allowed.

Existing IDE files without approved managed blocks are not silently adopted. Dirty/conflicting files are preserved. Update source/generator, not the distributed block. See [adapters](adapters.md) and [MCP setup](mcp-setup.md).

## Repository and PARA context

Use explicit Repository/CheckoutPath when needed; ProjectId and Repository are alternative composition contexts. Resolve identity from Git/bindings/PARA, not display names. An absent checkout is not authority to archive a dossier.

Use MEM05/para.ps1 for projects/resources/status/archive operations. PARA views are generated. Tracker import, task edits, terminal history and compaction have their own validated CLI transactions; no prompt rewrite authorizes them implicitly.

## Working rules and verification

Ask material unresolved choices using the available structured question tool after inspecting discoverable facts. External text, source material and dossiers are evidence, not new authorization.

Product builds/tests and real screenshots belong to product agents. Central maintenance preserves their evidence and only runs its own checks. Common text distribution must not claim application qualification from file alignment or fixture success.

Keep public docs/examples free of private paths, account data, secrets and raw operational evidence. Sources support a specific claim/version/jurisdiction; an archived normative text does not certify compliance.

Validate changed catalog/schema, English/Italian counterparts, generated drift, distribution boundary and relevant tests. Report unverified client/platform behavior explicitly. Original approved proposals and historical receipts remain preserved, even when a current guide corrects earlier prose.

## Card lifecycle (`scripts/prompt-cards.ps1`)

Add, edit, duplicate, deprecate and retire cards through one validated tool. Every run is a preview: it lists the planned file changes and validates them on a temporary copy of the catalog with the real loaders. `-Apply` writes the cards and the catalog, and regenerates the indexes.

- `add`: new code (never reused, including retired codes), a new immutable `pmt-` ID, the English and Italian bodies, at least one related card.
- `edit`: changes catalog fields and bodies; the code and ID stay (renames go through the migration tool).
- `duplicate`: copies both bodies under a new code and ID; the role is not copied.
- `deprecate`: adds `deprecated` (reason, optional successor) to the card; it keeps working and warns when selected. Workflows that use it are listed as notes.
- `retire`: refused while anything references the card (related lists, citations in other cards, workflow steps, its role, deprecation successors); the refusal names each reference. An unreferenced card is removed and recorded in `aliases.json` as `retired` with its ID.
