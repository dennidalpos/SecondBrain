#requires -Version 7.5
Set-StrictMode -Version Latest

# Message catalog: every user-visible message has a stable key and one English text.
# Placeholders use .NET composite format ({0}, {1}); a missing key returns the key itself.
$script:SBMessages = @{}

function Add-SBMessages([hashtable]$Messages) {
    foreach ($key in $Messages.Keys) { $script:SBMessages[$key] = $Messages[$key] }
}
function Get-SBMessage([string]$Key, [object[]]$Arguments = @()) {
    $entry = $script:SBMessages[$Key]
    if ($null -eq $entry -or -not $entry.ContainsKey('en')) { return $Key }
    $template = [string]$entry['en']
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { $template } else { $template -f $Arguments }
}
function New-SBError([string]$Key, [object[]]$Arguments = @(), [type]$Type, [int]$HResult = 0, [Exception]$Inner) {
    # The exception carries the stable key in Data['code'] so callers and tests match the code, not the text.
    $text = Get-SBMessage $Key $Arguments
    $exception = if ($Type -eq [IO.IOException]) {
        if ($Inner) { [IO.IOException]::new($text, $Inner) } elseif ($HResult) { [IO.IOException]::new($text, $HResult) } else { [IO.IOException]::new($text) }
    } else { [InvalidOperationException]::new($text) }
    $exception.Data['code'] = $Key
    $exception
}
function Test-SBError($ErrorRecord, [string]$Key) {
    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($null -ne $exception) {
        if ($exception.Data.Contains('code') -and $exception.Data['code'] -ceq $Key) { return $true }
        $exception = $exception.InnerException
    }
    $false
}

function Add-SBReportDiagnostic([System.Collections.IDictionary]$Record, [string]$Prefix) {
    # Only call on program-owned diagnostics: user notes and policy reasons are data.
    $reason = if ($Record.Contains('reason')) { [string]$Record.reason } else { '' }
    $Record['code'] = $null; $Record['message'] = $null
    if (!$reason) { return $Record }
    $key = $Prefix + '.reason.' + $reason
    $arguments = @()
    if ($reason -match '^http[-_](\d{3})$') { $key = $Prefix + '.reason.http'; $arguments = @([int]$Matches[1]) }
    if (!$script:SBMessages.ContainsKey($key)) { $key = 'report.reason.unverified' }
    $Record['code'] = $key
    $Record['message'] = Get-SBMessage $key $arguments
    $Record
}

Add-SBMessages @{
    'report.reason.unverified' = @{ en = 'Outcome could not be verified; see technical details' }
    'core.brainroot.invalid'    = @{ en = 'SECONDBRAIN_BRAIN_ROOT is not a SecondBrain checkout (VERSION and scripts/SecondBrain.Core.psm1 are missing): {0}' }
    'core.version.missing'      = @{ en = 'VERSION file missing: restore it from the checkout (git restore VERSION)' }
    'core.reparse.unwritable'   = @{ en = 'Reparse point is not writable: {0}' }
    'core.concurrent.modified'  = @{ en = 'Concurrent modification: {0}' }
    'core.runtime.reason.reparse-point' = @{ en = 'reparse point: not followed' }
    'core.runtime.reason.runtime-access' = @{ en = 'access sessions and locks' }
    'core.runtime.reason.runtime-hosts' = @{ en = 'workstation configuration and backups' }
    'core.runtime.reason.runtime-cleanup' = @{ en = 'cleanup log (recoverability proof)' }
    'core.runtime.reason.runtime-state' = @{ en = 'operational state' }
    'core.runtime.reason.runtime-para-marker' = @{ en = 'pending transaction marker' }
    'core.runtime.reason.config-path' = @{ en = 'configuration or workstation registry path' }
    'core.runtime.reason.protected-path' = @{ en = 'contains configuration or access paths' }
    'core.runtime.reason.recently-written' = @{ en = 'written in the last {0} minutes: it may be in use' }
    'core.runtime.reason.identity-unverified' = @{ en = 'workstation or owner identity is not verifiable' }
    'core.runtime.reason.unsupported-layout' = @{ en = 'outside the nested fixture/tmp layout: data retained' }
    'core.runtime.reason.foreign-host' = @{ en = 'folder belongs to another workstation: data retained' }
    'core.runtime.reason.foreign-owner' = @{ en = 'manifest belongs to another owner: data retained' }
    'core.runtime.reason.manifest-missing' = @{ en = 'MANIFEST.json missing: data retained' }
    'core.runtime.reason.manifest-invalid' = @{ en = 'manifest unreadable, unsupported or inconsistent with its path' }
    'core.runtime.reason.unknown-area' = @{ en = 'unknown area under repos/<repo>: expected work, evidence, report, fixture, tmp or temp' }
    'core.runtime.reason.unsupported-name' = @{ en = 'folder name outside the <yyyyMMdd>-<slug> form' }
    'core.runtime.reason.repository-mismatch' = @{ en = 'the manifest declares a repository different from the path segment' }
    'core.runtime.reason.host-mismatch' = @{ en = 'the manifest declares a workstation different from the path' }
    'core.runtime.reason.category-mismatch' = @{ en = 'the manifest declares a category different from the path' }
    'core.runtime.reason.name-mismatch' = @{ en = 'the manifest declares a name different from the folder' }
    'core.runtime.reason.foreign-content' = @{ en = 'consistent manifest, but the folder contains a .runtime layout of another repository (hosts/<id>/repos/<other>)' }
    'core.runtime.reason.legacy-layout' =@{ en = 'folder predates the nested layout (reorganize with cleanup.ps1 -Migrate)' }
    'core.runtime.reason.manifest-not-closed' = @{ en = 'manifest is not closed: data retained' }
    'core.runtime.reason.manifest-expiry-invalid' = @{ en = 'manifest expiry missing or invalid' }
    'core.runtime.reason.manifest-not-expired' = @{ en = 'expiry has not passed (the expiry day is included)' }
    'core.runtime.reason.journal-open' = @{ en = 'journal record is not completed: data retained' }
    'core.runtime.reason.retention' = @{ en = 'folder is among the latest retained per repository and category' }
    'core.runtime.reason.inspection-failed' = @{ en = 'inspection incomplete: the plan does not permit removal' }
    'core.runtime.reason.target-changed' = @{ en = 'target changed or no longer eligible after selection: data retained' }
    'core.runtime.regenerable.recovery' = @{ en = 'recreate with the suite or command identified by the manifest task; review references before authorizing' }
    'core.write.contended'      = @{ en = 'Write contended: the file is in use or was replaced by another writer: {0}' }
    'core.scope.invalid' = @{ en = 'Invalid coordination scope key' }
    'core.transaction.multiple' = @{ en = 'Multiple transaction markers exist: recover separately without overwriting them' }
    'core.write.denied'         = @{ en = 'Access denied while writing: {0}' }
    'core.write.retry'          = @{ en = 'Retry in PowerShell 7.5+ outside the sandbox: {0}' }
    'core.retry.parameter'      = @{ en = 'Invalid parameter name for the retry command' }
    'core.write.finalization'   = @{ en = 'Final record failed; original error preserved ({0}): {1}' }
    'trace.event.lost'          = @{ en = 'Trace event lost: {0}' }
    'core.state.root'           = @{ en = 'SECONDBRAIN_STATE_ROOT must name an absolute path on a fixed local drive outside the clone' }
    'core.tracked.dirty'        = @{ en = 'Tracked file has uncommitted changes: {0}. Commit or stash (git stash) the file changes, then retry.' }
    'core.readback.staging'     = @{ en = 'Staging readback failed' }
    'core.race.kept'            = @{ en = 'Write race detected; concurrent copy kept: {0}' }
    'core.backup.unverified'    = @{ en = 'Backup not verified; local recovery: {0}' }
    'core.readback.destination' = @{ en = 'Destination readback failed: {0}' }
    'core.staging.kept'         = @{ en = 'Transactional staging kept: {0}' }
    'core.migrate.destination'  = @{ en = 'Destination already exists: {0}' }
    'core.olderthan.min'        =@{ en = 'OlderThanDays must be at least 1' }
    'core.runtime.outside'      = @{ en = 'Path outside .runtime' }
    'core.runtime.reparse'      = @{ en = 'Reparse point cannot be removed by this step' }
    'core.checkout.ambiguous'   = @{ en = 'Ambiguous checkout binding' }
    'core.origin.changed'       = @{ en = 'Origin changed: explicit reconciliation required' }
    'core.workstation.invalid'  = @{ en = 'Invalid WorkstationId' }
    'core.output.outside'       = @{ en = 'Operational output outside SecondBrain/.runtime: {0}' }
    'core.block.duplicate'      = @{ en = 'Duplicate block: {0}' }
    'core.block.incomplete'     = @{ en = 'Incomplete block: {0}' }
    'core.remove.outside'       = @{ en = 'Removal outside scope: {0}' }
    'core.remove.changed'       = @{ en = 'File changed before removal: {0}' }
    'core.remove.concurrent'    = @{ en = 'Concurrent modification before removal' }
    'core.git.batchcheck'       = @{ en = 'Git cat-file --batch-check failed: {0}' }
    'core.git.stream'           = @{ en = 'Git cat-file --batch: stream interrupted' }
    'core.git.header'           = @{ en = 'Git cat-file --batch: unexpected header: {0}' }
    'core.git.timeout'          = @{ en = 'Git timeout: {0}' }
    'core.remove.backup'        = @{ en = 'Removal backup not verified' }
}

Export-ModuleMember -Function Add-SBMessages, Get-SBMessage, New-SBError, Test-SBError, Add-SBReportDiagnostic
