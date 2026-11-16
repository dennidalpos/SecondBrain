# Subagent definitions (F8)

One versioned format describes a subagent: role, initial context, permissions and the SecondBrain MCP tools it may call. Definitions are dossier assets, exported per client, and their jobs enter the [activity register](activity-register.md) with a reference to the parent agent. Development status: implemented and verified on synthetic fixtures; no live client has loaded an exported definition yet (the export marks `liveVerified=false`).

## Definition (schemaVersion 1)

Stored as `<dossier>/subagents/<name>.json`; the file name must equal `name` (`^[a-z0-9][a-z0-9-]{0,63}$`). Unknown fields, foreign files in the folder and unknown tools are errors.

| Field | Meaning |
|---|---|
| `schemaVersion` | `1` |
| `name`, `description` | Identity and one-line purpose (up to 8192 characters) |
| `role`, `context` | System role and initial context text |
| `permissions.tools` | Allowed MCP tools: `get_startup_context`, `get_ready_tasks`, `get_task`, `search_knowledge`, `list_prompts`, `get_prompt_home`, `get_prompt`, `check_publication`, `preview_dossier_write`, `submit_dossier_write` |
| `permissions.write` | `true` only to list the write tools; it carries no authorization |

Schema 1 is still read and validated unchanged. It has the fixed delegation depth 1 and no declared budget.

## Definition (schemaVersion 2)

Schema 2 implements section 4 of the [asset contracts](asset-contracts.md#4-agent-definition). It keeps every schema 1 field and adds identity, lifecycle, composable cards, an output contract and delegation bounds. Unknown fields (including `i18n`) are errors.

| Field | Meaning |
|---|---|
| `schemaVersion` | `2` |
| `id` | `agt-` plus 8 lowercase hex digits; immutable and unique among the dossier's definitions |
| `revision` | Positive integer, increased on any contract change |
| `status` | `draft`, `active`, `deprecated` or `retired` |
| `replacedBy` | Optional `agt-` ID of the successor; allowed only with `deprecated` or `retired` |
| `cards` | Optional list of `pmt-` IDs or roles the agent may compose (no card codes, no duplicates) |
| `output` | `{kind: text\|report\|object, schema?}`; `schema` is a `config/<path>.json` and is required for `object` |
| `bounds` | `{depth: 1, budget: {turns?, minutes?}}`; `depth` must be 1 (a delegate cannot delegate); `budget` needs at least one of `turns` (1–1000) or `minutes` (1–1440) |

| `model` | Optional `{provider: any\|claude\|codex\|gemini, name?}`; `name` needs a provider other than `any`. A preference for the parent, never a permission |

Example:

    {
      "schemaVersion": 2, "id": "agt-1a2b3c4d", "name": "reviewer", "revision": 1, "status": "active",
      "description": "Reviews one task read-only.", "role": "You are a read-only reviewer.",
      "context": "Start from the tracker task; cite sources.",
      "permissions": {"tools": ["get_task", "search_knowledge"], "write": false},
      "cards": ["analysis.task"], "output": {"kind": "report"},
      "bounds": {"depth": 1, "budget": {"turns": 20}}
    }

**Cards and mode.** `Validate`, `Resolve` and `Export` resolve each card against the public catalog `direttive/prompts/catalog.json`: a `pmt-` ID must match one card, and a role must be declared on exactly one active card. Draft and retired cards are not composable. A definition with `permissions.write=false` composes only `read` cards; `verify` and `write` cards need `write=true`. A card above that mode is an error, as is a definition with cards when no catalog is available. Private catalogs (`prompts/catalog.json` in the dossier) are not resolved yet. Until the catalog declares roles, only `pmt-` IDs resolve.

**Lifecycle.** `Export` leaves out `draft` and `retired` definitions and lists them under `skipped`. `deprecated` definitions are still exported.

## Permissions never exceed the parent

`Resolve` intersects a definition with the parent's tools and write flag. A tool or write flag the parent lacks is an error, never trimmed silently. Even with `write=true` on both sides, writes go through the parent's reviewed MCP write path (preview, plan hash, approval: F5); a definition cannot hold a permit.

## Commands

    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Validate -Repository <identity>
    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Resolve -Repository <identity> [-ParentTools <tools>] [-ParentWrite]
    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Export -Repository <identity> -Client claude-code -OutputPath .runtime/export/agents [-Apply]

`Validate` lists each definition with its schema version, ID, hash and resolved cards. `Resolve` adds, per agent, the effective permissions, `id`, `revision`, `status`, `replacedBy`, `output`, `bounds` (`depth` 1 and `budget`, `null` for schema 1), `maxCardMode` and the resolved `cards` (`ref`, `id`, `code`, `mode`, `status`).

`Export` previews unless `-Apply`, writes only under `.runtime` and never into a checkout: copy the package where the client expects it. `claude-code` produces `.claude/agents/<name>.md` with only the allowed `mcp__secondbrain__*` tools; the file is the same for schema 1 and 2. `codex` produces `.codex/agents/<name>.toml` (`name`, `description`, `developer_instructions`, optional `model`) and `gemini` produces `.gemini/agents/<name>.md` (frontmatter `name`, `description`, `kind: local`, `tools` as `mcp_secondbrain_<tool>`, optional `model`, `max_turns`, `timeout_mins`; Gemini CLI loads agents only with `experimental.enableAgents`). Formats follow the vendor pages recorded in [source provenance](source-provenance-3-0.md) (checked 2026-11-16); no live client has loaded them (`liveVerified=false`, live qualification stays in #351 and #512). Other clients get the normalized JSON (with the schema 2 fields for a schema 2 definition). Without `-ParentTools` the parent is read-only with all read tools.

Each exported file carries two reports. `unsupported` lists the definition fields the client format cannot represent (for example `id`, `revision`, `cards`, `output` and `bounds` for Claude Code, or `permissions.tools` and `permissions.write` for Codex): nothing is dropped silently. `enforcement` separates what the client enforces (`client-allowlist`: the `tools` allowlist of Claude Code and Gemini CLI) from what is only declared (Codex inherits the parent's tools and sandbox, so the allowed tools appear as instruction text; write access is declared, never enforced by the file). `-Probe` adds the installed CLI's status and version (`probe`).

## Management (#622)

Schema 2 definitions are authored and retired with the same script. Every operation previews unless `-Apply`, validates the result like `Validate` (including the cards against the catalog), writes with a verified backup and never changes a definition of another repository.

    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Create -Repository <identity> -DefinitionPath new-agent.json [-Apply]
    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Edit -Repository <identity> -Name reviewer -DefinitionPath wording.json [-Apply]
    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Revise -Repository <identity> -Name reviewer -DefinitionPath reviewer.json [-Apply]
    pwsh -NoProfile -File scripts/subagents.ps1 -Operation Retire -Repository <identity> -Name reviewer -Status deprecated -ReplacedBy agt-1a2b3c4d [-Apply]

- **Create** assigns `agt-` plus 8 hex digits when `id` is missing (never an ID already in use, retired ones included), forces revision 1 and defaults the status to `draft` (`active` is allowed; the other states are reached by `Retire`).
- **Edit** changes only `description` and `context`; the revision stays. A change to `role`, `permissions`, `cards`, `output` or `bounds` is refused: use Revise.
- **Revise** takes the full definition of the same `id` and `name`, bumps the revision by one (a kept or missing number is replaced by the next one) and refuses a breaking change: a widened permission (write, an added tool) or a changed output contract needs a new definition and `Retire` of the old one with `replacedBy`.
- **Retire** moves the status forward only (active to deprecated to retired, `-Status`), optionally records `-ReplacedBy` (an existing active or draft definition). The file and its ID stay on disk.

**Creation wizard (#623).** The Tracker tab of the [desktop app](../orchestratore.md) has a seven-step wizard for a new definition: purpose and template, target dossier, provider and model, tools and permissions, prompts (role, context, cards), budget and output, preview and save. Each step is checked before the next opens (the script remains the final judge). The last step runs `Create` without `-Apply` and shows the definition from the script's answer (`definition`, with the assigned `id`); Save sends that same previewed definition with `-Apply`, so the file equals the preview. Changing any value discards the preview. The end-to-end scenario is in `app/orchestrator/e2e/orchestrator.spec.ts`.

## Shipped presets (#624)

`direttive/agents/presets/` holds 24 schema 2 definitions (status `active`, revision 1, IDs `agt-5e000001` to `agt-5e000018`): repo-explorer, requirements-analyst, planner, implementer, debugger, code-reviewer, unit-tester, integration-tester, ui-tester, accessibility-reviewer, security-reviewer, dependency-reviewer, performance-analyst, documentation-writer, release-checker, ci-diagnostician, data-analyst, query-validator, researcher, document-drafter, document-reviewer, tutor, personal-project-planner and file-organizer. They are supported use cases, not a popularity ranking, and are copied into a dossier's `subagents/` folder with `Create`.

Schema 2 has no dedicated fields for sources and boundaries, so each `context` declares five labelled lines: `Sources`, `Boundaries`, `Tools` (equal to `permissions.tools`), `Writes` and `Expected output`. `permissions.write` is true only for documentation-writer, document-drafter and personal-project-planner, and then only through the reviewed MCP write path. `test-secondbrain-subagents.ps1` validates all 24 and checks those lines. Native client loading is not covered here.

## Preset fixture evaluations (#625)

`direttive/agents/evaluations/fixtures.json` gives each of the 24 presets one synthetic scenario (for example a fixture diff for code-reviewer, a CSV of synthetic orders for data-analyst, a CI log for ci-diagnostician). The `subagents` fixtures in `test-secondbrain-subagents.ps1` (run by `-Only trace`) evaluate each definition against its scenario and fail on any miss:

- the tools the scenario needs are in `permissions.tools`, and a dossier write is needed only where `permissions.write` is true;
- the output kind matches, and `context` declares the scenario's expected output and its boundary;
- the definition resolves under a parent with full permissions, and a write preset is refused under a read-only parent.

Result of the recorded run: 24 of 24 presets pass. This is a static evaluation of the definitions on synthetic scenarios; no model was run and no live client loaded a preset. The presets are supported use cases and the evaluation does not rank them by popularity or quality.

## Register

Subagent jobs are ordinary records with two extra fields, `parent` (the parent's `session`) and `agent` (the definition name). They go together, require `source=mcp`, and the parent session must already be in the register for the same repository, otherwise the append is rejected. Build them with `New-SBSubagentActivityRecord`; appending still needs `activityLogEnabled` (activation: #348).

## Running agents (#627)

`scripts/agent-runs.ps1` starts, stops, inspects and resumes one agent run. A run is a private record `<run root>/<run id>/agent-run.json` (run root under `.runtime`, run ID `run-` plus 8 hex digits) that holds the definition's `id`, `name` and `revision` (never a copy of the definition), the task, the parent session, the state and one entry per attempt (start, end, process ID, process start time, outcome). States: `running`, `waiting-user`, `stopped`, `finished`, `failed`.

    pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Start -Repository <identity> -RunRoot .runtime/agent-runs -Name reviewer [-TaskId <id>] [-ProcessId <pid>] -Apply
    pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Inspect -Repository <identity> -RunRoot .runtime/agent-runs [-RunId run-1a2b3c4d]
    pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Wait -Repository <identity> -RunRoot .runtime/agent-runs -RunId <run> -DecisionId dec-0a1b2c3d -Apply
    pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Resume -Repository <identity> -RunRoot .runtime/agent-runs -RunId <run> [-ProcessId <pid>] -Apply
    pwsh -NoProfile -File scripts/agent-runs.ps1 -Operation Stop -Repository <identity> -RunRoot .runtime/agent-runs -RunId <run> [-Outcome stopped|finished|failed] -Apply

- **Start** needs an `active` schema 2 definition. `-ProcessId` is the process the caller launched; the record keeps its start time so a reused ID is never mistaken for it.
- **Stop** ends the recorded process only when its ID and start time still match, closes the attempt and marks the run.
- **Wait** links the run to a decision of `decisions.json`. **Resume** of a waiting run requires that decision to be answered by the user; an open or withdrawn decision blocks it. Stopped runs resume without a decision. Each resume is a new attempt.
- **Inspect** is read-only and reports state, attempts and whether the last process is still alive.
- Start, Stop, Wait and Resume preview unless `-Apply`. No service, scheduled task or background auto-resume exists: every transition is an explicit call. Verified on fixtures only (`liveVerified=false`); no live agent CLI is launched by this script.
