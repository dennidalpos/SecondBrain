# Prompts

Catalog 4.0 has 127 prompt cards in 19 categories and 14 presets. The cards are in English.

~~~text
sb prompt list
sb prompt area quality
sb prompt show REV01
sb prompt REV01: review pull request 123
~~~

See the generated [catalog](../directives/prompts/README.md).

## Two layers

- **Development and IDE-use cards** (kind `user`, 74 base cards plus 18 in optional packs): small, single-purpose cards that follow what public prompt libraries share. Analysis and suggestion come first, the human approves before a change lands, and no base card deletes files, branches or history or changes platform settings.
- **System cards** (kind `system`, 35 in all): the prompts behind the `sb` commands (sessions, tasks, workstation, dossier, upkeep). They have nothing to do with the development cards and are not part of the community catalog. The `sb prompt` home lists every command with its purpose, mode, script and prompt card.

## Where you are

`sb prompt` (`scripts/prompts.ps1`) reads the current folder and names its location: a **managed repository** (dossier, tracker and runner available), a **repository not onboarded** (reduced mode), the **SecondBrain checkout**, or **no project**. The home shows the commands in two groups, repository commands and SecondBrain activation and maintenance, the presets, the standard starting chain and the guides.

**Standard starting chain:** `sb prompt session.start`, then `sb prompt task.work` or `sb runner`, and `sb prompt session.close` when the work is done. `sb stop` saves a handoff report in the dossier so `sb prompt session.resume` can continue from another IDE or account. Every composed prompt ends with `<next_steps>`: two to four next prompts and ready tasks, proposed as a multiple choice.

**Without onboarding** a repository still works: repository prompts are composed without a dossier and carry a `<degraded>` block. Startup context, tracker, runner, handoff reports, memory writes and `sb check` of that repository need onboarding (`sb activate`).

## Presets

A preset chains cards for a bigger job: `refactor`, `feature-from-issue`, `fix-defect`, `security-review`, `repo-audit`, `publish`, `site-build`, `session-start`, `session-close`, `first-setup`, `prepare-unattended`, `dossier-tidy`, `refresh-sources`, `maintenance-round`. `sb prompt wf-NAME: objective` runs a whole preset as one document: the steps in order, each with its composed card and its gate (`scripts/prompts.ps1 -Preset wf-NAME` also takes `-Skip step,...` for optional steps and `-Choose @{step=CODE}` for choice steps; an unknown preset, a skipped required step or an invalid choice is refused). You can also run the steps one by one with `sb prompt CODE: objective`. A step with the `confirm` gate asks for your approval before it writes; optional steps can be skipped. Presets live in `directives/prompts/workflows/`.

## Card structure

Cards follow the RCTFE layout: one task per card, a title line equal to the catalog `summary` (at most 80 characters after the code), and at most 3,500 characters.

| XML tag | Content |
|---|---|
| `role` | The agent's responsibility |
| `context` | When to use the card and its limits, the inputs it needs and the choices to ask the user |
| `task` | Ordered, numbered steps |
| `format` | The required report, then `Constraints:` and `Exit criteria:` |
| `examples` | Optional worked examples |

Every card has one mode (read, verify or write), one target and one outcome. A card that writes shows its plan and waits for approval. Composition combines the objective, repository context and card in XML with `role`, `context`, `task`, `format`, `operating_rules` and `next_steps`. The card organizes the task; it does not grant permissions.

## Categories

A repository prompt works only on the repository it runs from; central prompts run from the SecondBrain checkout.

**Current repository: run from the repository you work on**

| ID | Area | Codes |
|---|---|---|
| `understand` | Understand code and projects | UND01, UND02, UND03, UND04, UND05, UND06, UND07, UND08, UND09, UND10, UND11, UND12 |
| `plan` | Requirements, design and planning | PLN01, PLN02, PLN03, PLN04, PLN05, PLN06, PLN07, PLN08 |
| `build` | Change code | BLD01, BLD02, BLD03, BLD04, BLD05, BLD06, BLD07, BLD08, BLD09, BLD10, BLD11, BLD12, BLD13 |
| `quality` | Tests and verification | QUA01, QUA02, QUA03, QUA04, QUA05, QUA06, QUA07, QUA08 |
| `review` | Review and audit | REV01, REV02, REV03, REV04, REV05, REV06, REV07, REV08, REV09 |
| `risk` | Security, privacy and licenses | RSK01, RSK02, RSK03, RSK04, RSK05, RSK06, RSK07, RSK08 |
| `data` | Data and APIs | DTA01, DTA02, DTA03 |
| `interface` | Interface and accessibility | UIX01, UIX02, UIX03 |
| `docs` | Documentation and diagrams | DCM01, DCM02, DCM03, DCM04 |
| `release` | Release, pipelines and incidents | REL01, REL02, REL03 |
| `git` | Git and GitHub | GIT01, GIT02, GIT03 |
| `session` | sb system: sessions | SES01, SES02, SES03, SES04 |
| `tracker` | sb system: tasks, memory and tracker | TRK01, TRK02, TRK03, TRK04, TRK05, TRK06, TRK07, TRK08, TRK09, TRK10, TRK11 |
| `web` | Websites and web apps (optional pack) | SIT01, SIT02, SIT03, SIT04, SIT05, SIT06, SIT07, SIT08, SIT09 |
| `ai` | AI features and company AI (optional pack) | LLM01, LLM02, LLM03, LLM04, LLM05, LLM06, LLM07, LLM08, LLM09 |

**Central SecondBrain: run from the SecondBrain checkout**

| ID | Area | Codes |
|---|---|---|
| `knowledge` | sb system: dossier, sources and entities | KNW02, KNW03, KNW04, KNW05 |
| `workstation` | sb system: workstation, IDEs and MCP | WKS01, WKS02, WKS03, WKS04, WKS05, WKS06, WKS07, WKS08, WKS09 |
| `library` | sb system: catalog, directives and skills | DIR01, DIR03 |
| `upkeep` | sb system: SecondBrain upkeep | UPK01, UPK02, UPK03, UPK04, UPK05 |

## Where the catalog comes from

The base catalog follows the tasks that public prompt libraries share (Claude Code common workflows, GitHub Copilot prompt files and cookbook, the OpenAI Codex cookbook and the awesome-copilot community skills, read on 2026-11-22; sources registered in `shared/authoritative-sources/`). Cards were kept, split or added by that consensus. Cards for site and company-AI strategy have no match in those lists and live in the optional packs `site` and `llm`. Cards that delete files, branches or history, change platform settings or decommission a repository were removed from the base catalog.

Security and supply-chain areas follow the practice groups of NIST SP 800-218 SSDF 1.1. Codes are rewritten in 4.0 without aliases: an old code is unknown, and the old-to-new table is in `CHANGELOG.md`. Immutable IDs of kept cards did not change.

## Modes

| Icon | Mode | Meaning |
|---|---|---|
| 🔭 | Read | Analyze and report |
| ✅ | Verify | Compare evidence with pass/fail criteria |
| 🔥 | Write | Change authorized files or state |
| ⛔ | Destructive | Requires explicit confirmation for irreversible work; no base card is destructive |

These modes describe the workflow, not an exemption from session permissions or tool side effects.

## Customize

Use the library-edit card to add, change or retire a card or preset:

~~~text
sb prompt library.edit: add a card for reviewing database migrations
~~~

Maintain the English card and the catalog, then run:

~~~powershell
pwsh -NoProfile -File scripts/build-prompts.ps1 -Check
~~~

Regeneration is a writing operation. Common instructions require a concrete proposal, explicit approval and verified hashes before distribution. See [customization](reference/customizing-prompts-and-directives.md).
