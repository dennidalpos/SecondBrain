# Access and concurrency

Initial instruction and dossier reads do not need a Hold process. A single CLI write manages its own operation locks. Inspect sessions and queued writers with:

~~~powershell
pwsh -NoProfile -File scripts/access.ps1 -Status
pwsh -NoProfile -File scripts/access.ps1 -Queue
~~~

A stale heartbeat is evidence to investigate, not permission to take a live lock. Purge is an explicit maintenance operation; ordinary inspection does not remove sessions.

## Write sessions

Open, perform the authorized work and close in the same script:

~~~powershell
$session = & pwsh -NoProfile -File scripts/access.ps1 -Start -Mode Write -Client Codex -Repository github.com/example-user/my-app -TargetPath C:/Projects/MyApp | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { return }
try {
    & pwsh -NoProfile -File scripts/secondbrain.ps1 -Sync -SessionId $session.sessionId
} finally {
    & pwsh -NoProfile -File scripts/access.ps1 -End -SessionId $session.sessionId
}
~~~

Replace the example identity and checkout with the actual binding. Pass ConfigPath for a nondefault configuration and inspect each child exit code before continuing dependent work.

Sessions expire by themselves after 30 minutes without renewal (`sessionTimeoutSeconds` in `config/shared.json`, integer 10-86400, default 1800): the lease and heartbeat end, an exclusive session releases writer.lock and its SessionId can no longer write. If the helper process is interrupted the session reports abandoned and the lock is free. Use Renew with the same SessionId to continue. Start launches a hidden helper maintaining the lease and heartbeat. A normal Write session records identity without holding writer.lock throughout the session. Exclusive sessions are for explicitly bounded exclusive work.

## Locks

writer.lock admits one writer; operation.lock serializes central operations, including operations from the same session. FIFO tickets have exclusive leases. Recovery of a dead process's ticket does not steal a live lock.

### Per-dossier locks (#476)

Integrating a deferred write, or applying a task batch, changes one dossier only, so it takes a lock scoped to that dossier instead of the global one. Two dossiers write in parallel, and no write is left deferred because another dossier is busy.

- Scope key: `Get-SBScopeKey <repository identity>` is `r` plus 16 hex characters of the SHA-256 of the lowercased identity; a request with no identity uses `unscoped`. Callers pass it as `Enter-SBOperation -Scope`.
- Scoped files live in `.runtime/access/scopes/<key>/`: `writer.lock`, `operation.lock`, `operation-owner.json`, `queue/` (FIFO tickets, same rules as the global queue) and `para-transaction.json` (the marker of that dossier's interrupted transaction).
- Gate: `.runtime/access/scope.gate` joins the two levels. Scoped writers open it with shared access, so they never block one another. A global writer (PARA changes, setup, reconcile, exclusive sessions, every writer called without `-Scope`) opens it exclusively and so waits for every scoped writer, and holds off new ones until it ends. A writer in a scope waits for the global writer within the usual wait.
- `workstations.json` is checked and updated under the short `registry.lock`, because scoped writers can start together.
- Transactions: `Invoke-SBParaTransaction -Scope` writes the marker under the scope; without `-Scope` the scope is taken from the dossier that holds every operation path (`Get-SBDossierScope`: `repos|workstation/<dossier>/repository.json` identity), so tracker, merge, memory and compaction writes of one repository are scoped without their callers passing it. Paths of two repositories, or outside a repository dossier, keep the global marker. A scoped marker blocks only its own dossier (`Get-SBPendingTransaction <root> <key>`, `Read-SBConfiguration -Scope <key>`); a global marker blocks everyone, and readers and maintenance see all markers. Recover any marker with `scripts/recover.ps1 -ManifestPath <manifest>`; the manifest names its marker, and a transaction confined to one dossier is recovered under that dossier's lock only.
- Write commands: `knowledge.ps1 -Apply|-SetLifecycle|-DiscardPending` take the lock of the repository they act on (`-Repository`, the working checkout, or for `-DiscardPending` the repository that owns the request); `-All`, `-AllDossiers` and `-Customer` keep the global lock.
- Exclusive sessions: `access.ps1 -Start -Mode Write -Exclusive -Repository <managed identity>` holds only that repository's lock (the session records its `scope`); any other `-Repository` value keeps the brain-wide lock. A scoped session covers only its scope: operations on other scopes, and global ones, lock normally. `-Status` lists active owners with their scope and `-Queue` every queue (the global one and one per scope).
- Lock order is always gate, then writer.lock, then operation.lock; release is the reverse (`Close-SBWriterLock` releases the gate with the writer). The scoped path never takes the global writer.lock, so it cannot deadlock with a global writer.

The default writer wait is 60 seconds, controlled by WaitSeconds, SECONDBRAIN_LOCK_WAIT_SECONDS or shared lockWaitSeconds. Timeout returns exit 3 and reports the owner. Readers avoid blocking locks and report active writers or incomplete transactions. Knowledge reads never integrate queued writes; only an explicit knowledge.ps1 -FlushPending does, for the own dossier.

Custom central writes require Enter-SBOperation/Exit-SBOperation and expected hashes. A session alone does not protect direct filesystem edits from external editors. Use [deferred writes](pending-writes.md) for supported dossier changes.

## Workstation identity and limits

workstations.json binds workstationId to Windows identity and paths. A real relocation needs verification and explicit Reconcile; a different identity cannot reuse the same ID. Supported path aliases are normalized. Valid shared policy, including allowedOwners and excludedDirectories, is required; missing policy fails closed.

SessionId identifies work; Windows and SMB enforce actual access rights. Do not remove locks, journals or incomplete-transaction markers. Local alias tests do not establish real two-host SMB behavior. See [shared brain](shared-brain.md), [access CLI](../../scripts/access.ps1) and [protocol](../../scripts/SecondBrain.Access.psm1).
