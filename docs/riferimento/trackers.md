# Trackers and import

Resolve the active dossier by repository identity and PARA metadata. A `repository.json` declaration of `location=dossier`, `path=tracker.json` and `schemaVersion=1` makes that file authoritative. The bootstrap for a new checkout without a source tracker creates this declaration and an empty schema 1 tracker directly.

Ordinary reads of a greenfield dossier require the declaration. A missing declaration reports `tracker.greenfield.declaration.required`, a missing declared file reports `tracker.declared.missing`, and an incompatible payload version reports `tracker.schema.version`. These reads leave the files intact. An undeclared original source is discoverable for a greenfield dossier only through the explicit import workflow.

## Validation and reads

Schema 1 plus application checks validate identity/date, unique IDs, statuses, priority, dependencies and graph cycles across managed repositories. Acceptance criteria and imported statuses are data, not proof of completed work.

~~~powershell
pwsh -NoProfile -File scripts/knowledge.ps1 -Tasks -ReadyOnly -NoRecovery -CheckoutPath C:/Projects/MyProduct
pwsh -NoProfile -File scripts/knowledge.ps1 -Task TASK-ID -NoRecovery -CheckoutPath C:/Projects/MyProduct
~~~

The working repository resolves through explicit Repository or checkout/bindings/origin. Outside a resolvable checkout the CLI errors rather than listing unrelated work. All is an explicit paginated global read, incompatible with Repository. Task lookup includes archived IDs/sequences.

ReadyOnly resolves dependencies in active and historical trackers. Only completed outcomes satisfy dependencies. Fields include status, execution, priority, acceptance, evidence, provenance and optional sequence. The allowed statuses are todo, in_progress, blocked, done, cancelled and unknown.

## Changes and history

UpdateTaskId takes a task ID or `#<seq>` (padded or not) for a task of the same tracker by number, active or archived, like `-Task`; an unknown number is refused naming the ID form. It accepts Status, StateReason, Priority, Execution, DependsOn, Stream, Awaiting, Requires, Description, Acceptance (`;`-separated), Evidence (`reference|outcome`, outcome passed, failed, partial or unverified; appended, never cleared or replaced; `;` separates entries, each needs `|outcome`, so a reference with `;` or an empty value is refused; commas are kept in the reference) `-CorrectEvidence -CorrectionReason <text> [-Evidence <replacement list>]` (#669: the audited correction; without `-CorrectionAuthorization <owner authorization text>` it only previews the current and the replacement entries, with it the evidence is replaced, an omitted `-Evidence` removes every entry, the replaced entries stay in `extensions.evidenceCorrections` and the ledger gets an `evidence` record) and DecisionsFile (a JSON file of owner decisions `{question, answer}` stored in `extensions.decisions[]`). Omitted fields stay unchanged; at least one supplied field is required. DependsOn takes task IDs, `<repository>#<id>` for another managed repository, or `#<seq>` for a task of the same tracker by number, active or archived; `#<seq>` is stored as that task's ID and an unknown number is refused. Empty DependsOn clears dependencies and empty Stream removes it. Unknown tasks/repositories, invalid references, cycles and writes to another working repository are refused.

UpdateTasksFile (#595) applies several updates of the working repository's tracker from one JSON file, in one process, one writer lock and one transaction. The file is an array of updates, or `{"updates": [...]}`, at most 200. Each item names `taskId` (ID or `#<seq>`) and at least one of `status`, `stateReason`, `priority`, `execution`, `dependsOn` (array), `stream`, `awaiting`, `decision`, `requires` (array), `description`, `acceptance` (array), `evidence` (array of `reference|outcome` strings or `{reference, outcome}` objects) and `decisions` (array of `{question, answer}`), with the same rules as UpdateTaskId:

~~~powershell
@'
[
  {"taskId": "#595", "status": "done", "stateReason": "Batch form shipped", "evidence": ["scripts/test-secondbrain-pending.ps1|passed"]},
  {"taskId": "TASK-596", "priority": "P2", "stream": "prompts"}
]
'@ | Set-Content -LiteralPath $batchPath -Encoding utf8
pwsh -NoProfile -File scripts/knowledge.ps1 -UpdateTasksFile $batchPath -CheckoutPath $checkout
~~~

Each item still becomes its own request with the task hash and executor, and gets its own receipt (`batch.index` and `batch.size`); tracker, archive, ledger, requests and receipts are written by the same transaction. Applying the batch is all or nothing: an unknown field or task, an invalid value, the same task twice, or a task changed after the batch was prepared is refused as `Update <n> (<task>) refused, tracker unchanged: <reason>` (exit 2), and neither the tracker nor the queue changes. Unlike UpdateTaskId, a busy writer is not deferred: after the configured lock wait the command exits 3 without queuing anything, so run it again.

Readiness (#607): one deterministic assessment (`Get-SBTaskReadiness`) runs on every task creation (CLI `-NewTask`, MCP `task.new`) and every update of an open task (CLI, MCP, batch, the app's analysis), and is stored as `extensions.readiness` (`ready`, `missing`, and eight `checks`, each `passed` with its `missing` codes): objective (a meaningful title), scope (`stream` and description), inputs (provenance with hash), acceptance, dependencies (known, none cancelled), tools (known `requires` values), authorization (autonomous, not awaiting anyone) and decisions (no open `dec-` decision on the task). It informs; it never refuses a write. The import preview and manifest carry the same assessment per task without changing the imported tasks.

Autonomy check (#723): beyond the blocking checks, the assessment reports `advisory` items per task: `files` (extensions.files, the files in scope) and `checks` (extensions.checks, the commands to run) when they are missing. They do not block a task, so existing tasks keep running from the runner and the GUI queue; `Get-SBTaskReadiness -Strict` turns them into a blocking `verification` check. A task whose blocking checks pass (acceptance, scope, dependencies, tools, authorization, no open decision) runs from the queue without a question.

NewTask requires acceptance/provenance and a numbered tracker. Sequence is lastSeq+1; IDs/numbers are not reused. NewTask -FollowUpOf <id> links a follow-up to an active or archived source task (extensions.followUpOf) and inherits its stream. UpdateTaskId -EnrichmentFile <proposal.json> records only a pointer to a light-model proposal (extensions.enrichment: SecondBrain-relative path, hash, status). UpdateTaskId -ApplyEnrichment -EnrichmentAuthorization <text> applies only the proposal's fields (hash must match) and sets status applied; -RejectEnrichment sets rejected (#645). Imports keep ID, seq, acceptance and provenance byte-identical and add readiness in extensions only. RenumberTasks previews the migration and preserves original records by hash. With pwsh File, list arguments use semicolon separation as documented by the CLI.

Every change of status, execution or evidence also appends a record to the dossier ledger `history/task-runs.jsonl` in the same transaction, with the executor. `knowledge.ps1 -Registry` lists every task of the working repository, archived ones included, with the ledger and this workstation's runner reports (filters `-Tool`, `-TaskStatus`, `-Archived include|exclude|only`, `-Filter`; pages `-Page`/`-PageSize`, default 50). `-BackfillTaskRuns` copies older runner reports into the ledger, preview unless `-Apply`.

After verified acceptance, terminal done/cancelled records move into history/tracker-archive.json with IDs, numbers, evidence and provenance intact. Tracker/archive/queued receipt share one transaction. Reopening uses the same ID explicitly. Audit-only task proposals never apply these operations.

## Import workflow

Activation (SYS03) never seeds an empty tracker over a repository's own. For a new dossier it looks in the checkout, in the resolver's order, for `tracker.json`, `tracker.md`, `tasks.json` and `legacy-tasks.json`; `tracker.md` counts by existing, a JSON file only if it parses as an object. When one is found the dossier is created without `tracker.json` or a tracker declaration, the binding gets status `tracker-import-required`, and the activation report shows `trackerSource` with the relative `path` and `compatible` (true when the file passes the schema 1 checks once its `repository` is realigned to the target identity). The import below then makes the dossier tracker authoritative.

A source that is already schema 1 passes through the conversion unchanged: IDs, `seq`, statuses, evidence, provenance, dependencies, history and its own extensions (for example `lastSeq`) stay as they are. Only `repository` is realigned to the target identity; dependencies that named the original identity become same-repository ones, and the whole original document, original `repository` included, stays in `extensions.original`.

`import-tracker.ps1 -Repository <identity> -SourcePath <path>` previews source conversion. The supplied path must match the original source identified for the dossier. Supported collections preserve values and provenance. Ambiguous statuses or dependencies become unknown and block activation. Unsupported Markdown task rows raise an error.

Preparation Apply records manifest, verified exact original, candidate and recovery payload under backupRoot. A verified candidate is not yet authoritative. Activation needs separately approved concrete migration and Activate/Apply. Source changes after preparation block resume; do not edit hashes or candidate bytes to bypass it.

Manifest phases are pending/prepared/copied/verified/references_updated/originals_removed/completed. Rollback ends in rolled_back. `-ResumeManifest` reads the recorded state and `-RollbackManifest` previews recovery before Apply. These explicit commands also accept validated pre-1.0 `tracker-migration` journals. Check and PARA safety checks still detect their registered state.

Optional ReviewPath binds repository/sourceSha256 and explicit task status/dependency decisions with reasons. Its exact bytes/hash remain in manifest/history. It classifies imported data; it does not qualify application acceptance.

## Merge into an existing dossier tracker

When the dossier already exists and declares its own tracker, activation never imports over it. If the checkout also has a tracker (same candidate files and order as the import), the activation report keeps the binding `managed` and adds `trackerSource` plus `trackerMerge`: `status` (`ready`, `conflicts`, `up-to-date`, or `unplannable` with an `error`), `added`, `identical`, `alreadyMerged`, `conflicts` (each with `id`, `kind` and `detail`), `historyAdded`, the source and target hashes and `planSha256`. Nothing is written by the preview. `sb check` reports `tracker-merge` issues for a bound repository whose checkout tracker still has unmerged tasks or conflicts, and for a merge journal that did not complete.

The plan converts the source with the same conversion as the import (schema 1 passes through unchanged). A source task whose ID is new is added with its `seq`, evidence, provenance and dependencies untouched; a task identical to the dossier one (active or archived; the `extensions.readiness` assessment is ignored) needs nothing. Conflicts are never overwritten and block the apply: the same ID with other content (`content`, listing the differing fields), a `seq` already owned by another task (`seq`), a source task with status `unknown` (`review`), a history record with the same `reference` but other content (`history`), or a merged tracker that fails the schema or graph checks (`invalid`). New history records are appended, `extensions.lastSeq` never drops, and a history note and an `extensions.trackerMerges` receipt (source hash, archive, task hashes) are recorded. A task whose source version was merged earlier and then changed in the dossier is reported as `alreadyMerged`, not as a conflict.

```powershell
./scripts/import-tracker.ps1 -ConfigPath $cfg -Repository <identity> -SourcePath <checkout>/tracker.json -Merge
./scripts/import-tracker.ps1 -ConfigPath $cfg -Repository <identity> -SourcePath <checkout>/tracker.json -Merge -Apply -PlanSha256 <planSha256 of the preview>
./scripts/import-tracker.ps1 -ConfigPath $cfg -RollbackMerge $manifest
./scripts/import-tracker.ps1 -ConfigPath $cfg -RollbackMerge $manifest -Apply
```

Apply needs the `planSha256` of a preview of the current state (it covers the source and dossier tracker bytes); without it, or after either file changed, it is refused. Apply copies the source bytes to `history/tracker-merge-<hash>/` in the dossier, backs up `tracker.json` under backupRoot (`tracker-merge-<id>/`, verified by hash) and writes both in one PARA transaction. The checkout tracker is left in place. `-RollbackMerge` restores the verified backup and removes the files the merge created, and is refused when the dossier tracker changed after the merge. Limits: a dossier without a declared tracker still uses the import; sources that convert to `unknown` tasks (legacy files with unresolved dependencies) cannot be merged until they are reviewed; there is no partial apply of the non-conflicting tasks.

<a id="spostamenti-para"></a>

## PARA moves and diagnostics

Archive/Restore update registered operational references in the same transaction while preserving original payload hashes. Pending import phases prevent moves. Completed/rolled-back imports may move; a later tracker edit can still prevent rollback. A move is never implicit authorization to archive/restore.

Diagnostics separate stable code and localized message. Historical source text/provenance remain original. HistoryMessages is a derived language view; MigrateHistoryMessages previews then preserves originals on authorized Apply. This is not compaction.

Check validates declared sources, project references and registered migration state; it does not check all remote URLs/anchors or resolve GitHub exposure. A prepared import remains incomplete work.

Use bounded Write sessions and hash preconditions. See [deferred requests](pending-writes.md), [access](access.md), [recovery](recovery.md) and [runtime loading](runtime-maintenance.md).
