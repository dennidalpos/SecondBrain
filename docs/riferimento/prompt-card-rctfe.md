# RCTFE prompt card schema (first step of #721)

A prompt card is described by five parts: **R**ole, **C**ontext, **T**ask (a one-line plan and numbered steps), **F**ormat and constraints, and optional **E**xamples. The schema is `config/prompt-card-rctfe.schema.json`; `scripts/SecondBrain.PromptSchema.psm1` converts a legacy eight-section card and validates the result.

| RCTFE part | Legacy sections it takes |
|---|---|
| Role | `role` |
| Context | `context`, `inputs`, `decisions` (as "Decisions to ask the user") |
| Task | `procedure`: `plan` is the card title, `steps` are the numbered lines (at least 2) |
| Format and constraints | `output_format`, `constraints`, `exit_criteria` |
| Examples | none yet (optional) |

Card fields: `code`, `kind` (`system`: read-only, needed by SecondBrain; `user`), `description` (one line, at most 120 characters), optional `chain` of prompt IDs. The 3,500-character budget applies to role, context, steps and format together.

Status: the schema, converter and validator exist and are covered by `scripts/test-secondbrain-lint.ps1` on three real cards (SYS01, AIS01, DEV01). The live catalog and the 123 cards are not rewritten: that needs the catalog version bump (a released data format), the merge of duplicate cards and the system/user classification, which are decisions for the owner. The Prompts tab (#722) follows once the schema is fixed.
