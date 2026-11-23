# RCTFE prompt card schema (first step of #721)

A prompt card is described by five parts: **R**ole, **C**ontext, **T**ask (a one-line plan and numbered steps), **F**ormat and constraints, and optional **E**xamples. The schema is `config/prompt-card-rctfe.schema.json`; `scripts/SecondBrain.PromptSchema.psm1` converts a legacy eight-section card and validates the result.

| RCTFE part | Legacy sections it takes |
|---|---|
| Role | `role` |
| Context | `context`, `inputs`, `decisions` (as "Decisions to ask the user") |
| Task | `procedure`: `plan` is the card title, `steps` are the numbered lines (at least 2) |
| Format and constraints | `output_format`, `constraints`, `exit_criteria` |
| Examples | none yet (optional) |

Card fields: `code`, `kind` (`system`: the prompts behind the `sb` commands, in the sb system categories; `user`), `description` (one line, at most 120 characters; in the catalog it is the `summary`), optional `chain` of prompt IDs (the catalog `related`). The 4,500-character budget applies to role, context, steps and format together. In the card file the plan is the header title and `<task>` holds the numbered steps; `format` lists the report, then `Constraints:` and `Exit criteria:`.

Status: every card in the catalog is in this layout (catalog version 4, `kind` per prompt). `scripts/test-secondbrain-prompts.ps1` validates every card, `scripts/test-secondbrain-lint.ps1` covers the converter. Duplicate cards are not merged: a candidate report awaits the owner's confirmation. Private dossier cards keep the legacy layout. The Prompts tab (#722) follows.
