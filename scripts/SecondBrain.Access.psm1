#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'access.station.inactive' = @{ en = 'Workstation not activated: run the activation procedure (workstation.activate, scripts/secondbrain.ps1 -Setup)' }
    'access.config.missing' = @{ en = 'Configuration not found: {0}. Run Setup (sb activate)' }
    'access.brain.unreachable' = @{ en = 'SecondBrain root is unreachable: {0}. Check SECONDBRAIN_HOME and that the folder exists' }
    'access.config.chain' = @{ en = 'Invalid chain of migrated configurations' }
    'access.config.incomplete' = @{ en = 'Incomplete portable configuration: {0}' }
    'access.binding.invalid' = @{ en = 'Invalid repository binding' }
    'access.shared.incomplete' = @{ en = 'config/shared.json missing or incomplete (allowedOwners and excludedDirectories required): restore the shared policy' }
    'access.shared.owner' = @{ en = 'Invalid GitHub owner in config/shared.json' }
    'access.shared.sessiontimeout' = @{ en = 'sessionTimeoutSeconds in config/shared.json must be an integer between 10 and 86400' }
    'access.shared.lockwait' = @{ en = 'lockWaitSeconds in config/shared.json must be an integer between 0 and 600' }
    'access.config.required' = @{ en = 'Workstation configuration required: activate the workstation with secondbrain.ps1 -Setup (workstation.activate)' }
    'access.session.invalid' = @{ en = 'Invalid SessionId: use the one returned by access.ps1 -Start' }
    'access.queue.timeout' = @{ en = 'SecondBrain write queue not available within the wait time' }
    'access.session.missing' = @{ en = 'Session missing or not verifiable: start one with access.ps1 -Start' }
    'access.session.missing.write' = @{ en = 'Write session missing or not verifiable: start one with access.ps1 -Start' }
    'access.session.foreign' = @{ en = 'The session belongs to another user or workstation: start your own with access.ps1 -Start' }
    'access.station.identity' = @{ en = 'workstationId already registered with another identity: use a new id' }
    'access.station.roots' = @{ en = 'runtimeRoot and backupRoot must be distinct per workstation' }
    'access.station.moved' = @{ en = 'workstationId ''{0}'' already registered with different paths (registered: {1}; current: {2}). Check the move and reconcile with scripts/access.ps1 -Reconcile.' }
    'access.busy' = @{ en = 'SecondBrain busy or coordination unavailable after {0} s. Owner: {1}. Retry later or wait for the owner session to end' }
    'access.pending.who' = @{ en = ' started by {0}@{1} on {2}' }
    'access.pending' = @{ en = 'Incomplete dossier transaction{0} (manifest: {1}). Recover with scripts/recover.ps1 -ManifestPath <manifest> from any workstation that reaches the manifest; do not remove the marker by hand.' }
}

$script:SBWriterGates = @{}
function Get-SBPendingTransaction([string]$BrainRoot,[string]$Scope) {
    # Summarize an interrupted transaction marker: owner, time, manifest and reachability from this workstation.
    # A global marker always counts. Per-dossier markers (#476) count for every caller, except that -Scope limits them to that dossier's own.
    $marker=Get-SBTransactionMarkerPath $BrainRoot
    if(!(Test-Path -LiteralPath $marker)){
        $scoped=@(Get-SBScopedMarkerPaths $BrainRoot|Where-Object {!$Scope -or $_ -ieq (Get-SBTransactionMarkerPath $BrainRoot $Scope)})
        if(!$scoped.Count){return $null}
        $marker=$scoped[0]
    }
    $pending=try{Read-SBJson $marker @{}}catch{@{}}
    $manifest=if($pending.ContainsKey('manifest')){[string]$pending.manifest}else{''}
    if($manifest -and $pending.ContainsKey('brainRoot')){$manifest=Convert-SBBrainAlias $manifest ([string]$pending.brainRoot) $BrainRoot}
    @{marker=$marker;scope=$(if($pending.ContainsKey('scope')){[string]$pending.scope}else{''});manifest=$manifest;computer=$(if($pending.ContainsKey('computer')){[string]$pending.computer}else{''});user=$(if($pending.ContainsKey('user')){[string]$pending.user}else{''});startedAt=$(if($pending.ContainsKey('startedAt')){[string]$pending.startedAt}else{''});reachable=($manifest -and (Test-Path -LiteralPath $manifest))}
}
function Format-SBPendingTransaction($Pending) {
    $who=if($Pending.user -or $Pending.computer){Get-SBMessage 'access.pending.who' @($Pending.user,$Pending.computer,$Pending.startedAt)}else{''}
    (Get-SBMessage 'access.pending' @($who,$Pending.manifest))
}
function Get-SBLockWaitMs($Config,[int]$WaitMs=-1) {
    # Default writer wait on a shared brain: explicit parameter, then SECONDBRAIN_LOCK_WAIT_SECONDS, shared policy, then 60 s.
    if($WaitMs -ge 0){return $WaitMs}
    if($env:SECONDBRAIN_LOCK_WAIT_SECONDS -match '^\d{1,3}$'){return [Math]::Min([int]$env:SECONDBRAIN_LOCK_WAIT_SECONDS,600)*1000}
    if($Config -is [Collections.IDictionary] -and $Config.ContainsKey('lockWaitMs')){return [int]$Config.lockWaitMs}
    60000
}
function Read-SBConfiguration([string]$ConfigPath,[switch]$AllowPendingTransaction,[int]$MigrationDepth=0,[switch]$ReadOnly,[string]$BrainRoot,[string]$Scope) {
    # -Scope: the caller writes one repository dossier only; an interrupted transaction of another dossier no longer blocks it (a global marker still does).
    $brain = if($BrainRoot){[IO.Path]::GetFullPath($BrainRoot)}else{(Get-SBBrainRootPath)}
    if($brain.StartsWith('\\') -and ![IO.Directory]::Exists($brain)){throw (New-SBError 'access.brain.unreachable' @($brain))}
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
    $hostConfigPath=Get-SBHostConfigPath $brain
    if(!$ConfigPath){
        $ConfigPath=$hostConfigPath
        if(!(Test-Path -LiteralPath $ConfigPath)){throw (New-SBError 'access.station.inactive')}
    }elseif(!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){throw (New-SBError 'access.config.missing' @($ConfigPath))}
    $stateRoot=Split-Path $hostConfigPath -Parent
    $ConfigPath=Assert-SBSetupStatePath $brain $stateRoot $ConfigPath @('workstation.json')
    $externalState=($ConfigPath -ieq $hostConfigPath -and $stateRoot -ine (Get-SBLocalRoot $brain (Get-SBHostId)))
    $local = Read-SBJson $ConfigPath $null
    if($MigrationDepth -gt 3){throw (New-SBError 'access.config.chain')}
    if($local -and $local.ContainsKey('migratedTo')){
        $target=Assert-SBCentralDataPath $brain $local.migratedTo
        return Read-SBConfiguration $target -AllowPendingTransaction:$AllowPendingTransaction -MigrationDepth ($MigrationDepth+1) -ReadOnly:$ReadOnly -BrainRoot $brain -Scope $Scope
    }
    $shared = Read-SBJson (Join-Path $brain 'config/shared.json') $null
    if($local -and $local.schemaVersion -eq 1 -and $local.mode -eq 'portable'){
        foreach($key in @('workstationId','runtimeRoot','backupRoot','bindings','ides')){if(!$local.ContainsKey($key)){throw (New-SBError 'access.config.incomplete' @($key))}}
        if($local.workstationId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$'){throw (New-SBError 'core.workstation.invalid')}
        if($externalState -and $local.workstationId -cne (Get-SBHostId)){throw (New-SBError 'access.station.identity')}
        foreach($key in @('runtimeRoot','backupRoot')){
            $value=[string]$local[$key];if(![IO.Path]::IsPathFullyQualified($value)){$value=Join-Path $brain $value}
            $local[$key]=Assert-SBCentralDataPath $brain $value
        }
        foreach($binding in $local.bindings){if(!(Test-SBRepositoryIdentity $binding.identity) -or ![IO.Path]::IsPathFullyQualified($binding.path)){throw (New-SBError 'access.binding.invalid')}}
        # Shared policy (config/shared.json) is the only source of allowed owners and excluded folders, including portable mode.
        # Fail closed: without a valid policy, never assume that all owners are allowed.
        if(!($shared -is [Collections.IDictionary]) -or !$shared.ContainsKey('allowedOwners') -or !$shared.ContainsKey('excludedDirectories')){throw (New-SBError 'access.shared.incomplete')}
        $owners=@($shared.allowedOwners)
        foreach($owner in $owners){if($owner -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$'){throw (New-SBError 'access.shared.owner')}}
        $excludedDirs=@($shared.excludedDirectories)
        $local.brainRoot=$brain;$local.configPath=$ConfigPath;$local.repositoryRoot=$brain;$local.allowedOwners=$owners;$local.excludedDirectories=$excludedDirs;$local.sessionTimeoutMinutes=30
        $local.localStateRoot=if($externalState){$stateRoot}else{$local.runtimeRoot}
        $local.localStateBackupRoot=if($externalState){Join-Path $stateRoot 'backups'}else{$local.backupRoot}
        $local.coordinationRoot=Join-Path $brain '.runtime/access'
        # Writer wait: lockWaitSeconds in config/shared.json (0-600, default 60).
        $local.lockWaitMs=60000
        # Session expiry without renewal: sessionTimeoutSeconds in config/shared.json (10-86400, default 1800 = 30 minutes).
        if($shared.ContainsKey('sessionTimeoutSeconds')){
            $timeout=$shared.sessionTimeoutSeconds
            if(($timeout -isnot [int] -and $timeout -isnot [long]) -or $timeout -lt 10 -or $timeout -gt 86400){throw (New-SBError 'access.shared.sessiontimeout')}
            $local.sessionTimeoutMinutes=[double]$timeout/60
        }
        if($shared.ContainsKey('lockWaitSeconds')){
            $wait=$shared.lockWaitSeconds
            if(($wait -isnot [int] -and $wait -isnot [long]) -or $wait -lt 0 -or $wait -gt 600){throw (New-SBError 'access.shared.lockwait')}
            $local.lockWaitMs=[int]$wait*1000
        }
        $pending=Get-SBPendingTransaction $brain $Scope
        if($pending -and !$AllowPendingTransaction){
            # Readers continue with a warning: data may remain in an intermediate state until the manifest is recovered.
            if(!$ReadOnly){throw (Format-SBPendingTransaction $pending)}
            $local.pendingTransaction=$pending
        }
        return $local
    }
    throw (New-SBError 'access.config.required')
}

function Write-SBAccessMetadata([string]$Path, $Value) {
    Assert-SBPlainPath $Path
    $temp = $Path+'.'+(New-SBId)+'.tmp'
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $Value))
        $stream = [IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        # A reader on another host may briefly hold the file open: retry replacement instead of marking the session failed.
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try { [IO.File]::Move($temp,$Path,$true); break }
            catch [IO.IOException], [UnauthorizedAccessException] { if ($attempt -eq 6) { throw }; Start-Sleep -Milliseconds (40 * $attempt) }
        }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Test-SBSessionId([string]$SessionId) {
    if ($SessionId -notmatch '^[a-f0-9]{32}$') { throw (New-SBError 'access.session.invalid') }
}

function Open-SBLockFile([string]$Path, [IO.FileMode]$Mode, [IO.FileAccess]$Access, [IO.FileShare]$Share, [int]$WaitMs = 1000, [scriptblock]$OnWait) {
    $deadline = (Get-SBNow).AddMilliseconds([Math]::Max(0, $WaitMs))
    $delay = 100; $notified = $false
    while ($true) {
        try {
            return [IO.File]::Open($Path, $Mode, $Access, $Share)
        } catch [IO.IOException] {
            $hr = $_.Exception.GetBaseException().HResult -band 0xffff
            if ($hr -notin @(32, 33) -or (Get-SBNow) -ge $deadline) { throw }
            # Report the owner once, as soon as waiting begins.
            if ($OnWait -and !$notified) { $notified = $true; & $OnWait }
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min(500, [int]($delay * 1.5))
        }
    }
}
function Test-SBBusyError($ErrorRecord) {
    # Writer-lock contention after waiting (sharing/lock violation), excluding other I/O errors.
    $base = $ErrorRecord.Exception.GetBaseException()
    $base -is [IO.IOException] -and ($base.HResult -band 0xffff) -in @(32, 33)
}
function Test-SBQueueTicketAlive([string]$LeasePath) {
    # A ticket is live while its process holds the lease open; an openable lease belongs to an exited process.
    $probe = $null
    try { $probe = [IO.File]::Open($LeasePath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch [UnauthorizedAccessException] { return $false }
    catch [IO.IOException] { if (($_.Exception.HResult -band 0xffff) -in @(32, 33)) { return $true }; throw }
    finally { if ($probe) { $probe.Dispose() } }
}
function Remove-SBQueueTicketFiles([string]$Root, [string]$Name) {
    foreach ($suffix in @('.json','.lease')) { try { [IO.File]::Delete((Join-Path $Root ($Name+$suffix))) } catch { Write-Verbose $_.Exception.Message } }
}
function Get-SBQueueTicketNames([string]$Root) {
    # Arrival order: the name starts with fixed-width UTC ticks, followed by a GUID tie-breaker.
    if (!(Test-Path -LiteralPath $Root)) { return @() }
    $names = @(Get-ChildItem -LiteralPath $Root -Filter '*.lease' -File -ErrorAction SilentlyContinue | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $names
}
function Get-SBCoordinationScopeRoot($Config, [string]$Scope) {
    # Folder of one dossier's writer.lock, operation.lock, owner file and queue; the shared coordination root when there is no scope.
    if (!$Scope) { return $Config.coordinationRoot }
    Get-SBScopeRoot $Config.brainRoot $Scope
}
function Enter-SBQueue($Config, [int]$WaitMs, [scriptblock]$OnWait, [string]$Scope) {
    # FIFO writer queue over writer.lock: the ticket is an exclusive open lease; tickets from exited processes
    # (openable leases) are removed without touching writer.lock or transaction markers.
    $root = Join-Path (Get-SBCoordinationScopeRoot $Config $Scope) 'queue'
    Assert-SBPlainPath $root
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $name = (Get-SBNow).UtcTicks.ToString('D19') + '-' + (New-SBId)
    $leasePath = Join-Path $root ($name+'.lease')
    Assert-SBPlainPath $leasePath
    $ticket = @{ name=$name; root=$root; lease=[IO.FileStream]::new($leasePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    try {
        Write-SBAccessMetadata (Join-Path $root ($name+'.json')) @{ticket=$name;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;computer=[Environment]::MachineName;processId=$PID;client='SecondBrain script';workstationId=$Config.workstationId;enqueuedAt=(Get-SBNow).ToString('o')}
        $deadline = (Get-SBNow).AddMilliseconds([Math]::Max(0, $WaitMs))
        $delay = 100; $notified = $false
        while ($true) {
            $ahead = $null
            foreach ($other in @(Get-SBQueueTicketNames $root)) {
                if ($other -ceq $name) { break }
                if (Test-SBQueueTicketAlive (Join-Path $root ($other+'.lease'))) { $ahead = $other; break }
                Remove-SBQueueTicketFiles $root $other
            }
            if (!$ahead) { return $ticket }
            if ((Get-SBNow) -ge $deadline) { throw (New-SBError 'access.queue.timeout' @() ([IO.IOException]) -2147024864) }
            if ($OnWait -and !$notified) { $notified = $true; & $OnWait }
            Start-Sleep -Milliseconds $delay
            $delay = [Math]::Min(500, [int]($delay * 1.5))
        }
    } catch { Exit-SBQueue $ticket; throw }
}
function Exit-SBQueue($Ticket) {
    if (!$Ticket) { return }
    if ($Ticket.lease) { $Ticket.lease.Dispose() }
    Remove-SBQueueTicketFiles $Ticket.root $Ticket.name
}
function Open-SBWriterLock($Config, [string]$WriterPath, [int]$WaitMs, [scriptblock]$OnWait, [string]$Scope) {
    # Queue a ticket, then acquire writer.lock within the remaining wait; release the ticket as soon as the lock is acquired.
    # Per-dossier locks (#476): -Scope names the dossier; its writers share the gate (scope.gate) that a global writer holds exclusively,
    # so dossiers run in parallel while a global writer (PARA, setup, session) still excludes every one of them.
    $deadline = (Get-SBNow).AddMilliseconds([Math]::Max(0, $WaitMs))
    $state = @{ notified=$false }
    $notify = { if (!$state.notified) { $state.notified = $true; if ($OnWait) { & $OnWait } } }.GetNewClosure()
    $ticket = Enter-SBQueue $Config $WaitMs $notify $Scope
    $gate = $null
    try {
        $gatePath = Join-Path $Config.coordinationRoot 'scope.gate'
        Assert-SBPlainPath $gatePath
        $share = if ($Scope) { [IO.FileShare]::ReadWrite } else { [IO.FileShare]::None }
        $remaining = [int][Math]::Max(0, ($deadline - (Get-SBNow)).TotalMilliseconds)
        $gate = Open-SBLockFile $gatePath ([IO.FileMode]::OpenOrCreate) ([IO.FileAccess]::ReadWrite) $share $remaining $notify
        $remaining = [int][Math]::Max(0, ($deadline - (Get-SBNow)).TotalMilliseconds)
        $writer = Open-SBLockFile $WriterPath ([IO.FileMode]::OpenOrCreate) ([IO.FileAccess]::ReadWrite) ([IO.FileShare]::None) $remaining $notify
        # The writer handle owns the gate: Close-SBWriterLock releases both.
        $script:SBWriterGates[[string]$writer.SafeFileHandle.DangerousGetHandle()] = $gate
        $gate = $null
        $writer
    } catch { if ($gate) { $gate.Dispose() }; throw }
    finally { Exit-SBQueue $ticket }
}
function Close-SBWriterLock($Writer) {
    if (!$Writer) { return }
    $key = [string]$Writer.SafeFileHandle.DangerousGetHandle()
    $gate = $script:SBWriterGates[$key]
    $script:SBWriterGates.Remove($key)
    $Writer.Dispose()
    if ($gate) { $gate.Dispose() }
}
function Get-SBQueueStatus($Config, [switch]$Purge) {
    # Read-only (-Purge removes orphan tickets): position 1 = next writer, counted inside each queue (the global one and one per dossier scope).
    $roots = @(@{scope='';root=(Join-Path $Config.coordinationRoot 'queue')})
    $scopesRoot = Join-Path $Config.coordinationRoot 'scopes'
    if (Test-Path -LiteralPath $scopesRoot) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $scopesRoot -Directory | Where-Object { $_.Name -cmatch '^(unscoped|r[a-f0-9]{16})$' })) { $roots += @{scope=$dir.Name;root=(Join-Path $dir.FullName 'queue')} }
    }
    foreach ($item in $roots) {
        $root = $item.root
        $position = 0
        foreach ($name in @(Get-SBQueueTicketNames $root)) {
            $meta = Read-SBJson (Join-Path $root ($name+'.json')) @{}
            $alive = Test-SBQueueTicketAlive (Join-Path $root ($name+'.lease'))
            $entry = @{} + $meta
            $entry.ticket = $name
            $entry.scope = $item.scope
            if ($alive) { $position++; $entry.state = 'waiting'; $entry.position = $position } else { $entry.state = 'orphan'; if ($Purge) { Remove-SBQueueTicketFiles $root $name } }
            $entry
        }
    }
}
function Write-SBReadWarnings($Operation, $Config) {
    # Lock-free readers: warn on stderr about a potentially intermediate state without failing.
    if ($Operation -and $Operation.concurrentWriter) { [Console]::Error.WriteLine('Avviso: un writer SecondBrain e attivo, i dati letti possono essere intermedi.') }
    $pending = if ($Operation -and $Operation.pendingTransaction) { $Operation.pendingTransaction } elseif ($Config -is [Collections.IDictionary] -and $Config.ContainsKey('pendingTransaction')) { $Config.pendingTransaction } else { $null }
    if ($pending) { [Console]::Error.WriteLine('Avviso: ' + (Format-SBPendingTransaction $pending)) }
}
function Get-SBOperationOwnerText($Config, [string]$Scope) {
    $owners = @(Get-SBAccessStatus $Config|Where-Object {$_.status -eq 'active' -and $_.mode -eq 'Write' -and (!$_.ContainsKey('exclusive') -or $_.exclusive)})
    $owner = Read-SBJson (Join-Path (Get-SBCoordinationScopeRoot $Config $Scope) 'operation-owner.json') @{}
    if (!$owner.Count -and $Scope) { $owner = Read-SBJson (Join-Path $Config.coordinationRoot 'operation-owner.json') @{} }
    if ($owners.Count) { ($owners | ForEach-Object { "$($_.user)@$($_.computer), $($_.client), $($_.path), sessione $($_.sessionId)" }) -join '; ' }
    elseif ($owner.Count) { "$($owner.user)@$($owner.computer), $($owner.client), $($owner.path), dal $($owner.heartbeat)" }
    else { 'titolare non identificato' }
}

function Get-SBAccessStatus($Config, [switch]$Repair) {
    $root = Join-Path $Config.coordinationRoot 'sessions'
    $files=if(Test-Path -LiteralPath $root){@(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)}else{@()}
    foreach ($file in $files) {
        $entry = Read-SBJson $file.FullName $null
        if (!$entry -or $entry.status -notin @('active','abandoned')) { continue }
        $entry = @{} + $entry
        if ($entry.status -eq 'active') {
            $lease = $null
            try {
                $lease = [IO.File]::Open((Join-Path $root ($entry.sessionId+'.lease')),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                $entry.status = 'abandoned'
            } catch [IO.FileNotFoundException] { $entry.status = 'abandoned' }
            catch [IO.IOException] {
                if (($_.Exception.GetBaseException().HResult -band 0xffff) -notin @(32,33) -or ((Get-SBNow) - [DateTimeOffset]::Parse($entry.heartbeat)).TotalSeconds -gt 15) { $entry.status = 'unverified' }
            } finally { if ($lease) { $lease.Dispose() } }
            # Status is read-only: persisting abandonment requires -Repair (or Clear-SBStaleSessions).
            if ($Repair -and $entry.status -eq 'abandoned') {
                try { Write-SBAccessMetadata $file.FullName $entry } catch { Write-Verbose $_.Exception.Message }
                foreach ($suffix in @('.stop','.renew','.lease')) { [IO.File]::Delete((Join-Path $root ($entry.sessionId+$suffix))) }
            }
        }
        $entry
    }
    # Active writers of the global lock and of every dossier scope; a scoped owner carries its scope key.
    $ownerRoots=@(@{scope='';root=$Config.coordinationRoot})
    $scopesRoot=Join-Path $Config.coordinationRoot 'scopes'
    if(Test-Path -LiteralPath $scopesRoot){
        foreach($dir in @(Get-ChildItem -LiteralPath $scopesRoot -Directory|Where-Object {$_.Name -cmatch '^(unscoped|r[a-f0-9]{16})$'})){$ownerRoots+=@{scope=$dir.Name;root=$dir.FullName}}
    }
    foreach($item in $ownerRoots){
        $owner=Read-SBJson (Join-Path $item.root 'operation-owner.json') $null
        if($owner){
            $probe=$null
            try{$probe=[IO.File]::Open((Join-Path $item.root 'writer.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
            catch [IO.IOException]{if(($_.Exception.GetBaseException().HResult -band 0xffff) -in @(32,33)){$owner.status='active';$owner.scope=$item.scope;$owner}}
            finally{if($probe){$probe.Dispose()}}
        }
    }
}

function Clear-SBStaleSessions($Config, [int]$MaxAgeMinutes = 60) {
    $root = Join-Path $Config.coordinationRoot 'sessions'
    if (!(Test-Path -LiteralPath $root)) { return 0 }
    $removedCount = 0
    $cutoff = (Get-SBNow).AddMinutes(-[Math]::Max(0, $MaxAgeMinutes))
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $entry = Read-SBJson $file.FullName $null
        if (!$entry) { continue }
        $status = $entry.status
        if ($status -eq 'active') {
            $lease = $null
            try {
                $lease = [IO.File]::Open((Join-Path $root ($entry.sessionId+'.lease')),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                $status = 'abandoned'
            } catch [IO.FileNotFoundException] { $status = 'abandoned' }
            catch [IO.IOException] { Write-Verbose $_.Exception.Message }
            finally { if ($lease) { $lease.Dispose() } }
            if ($status -eq 'abandoned') {
                $entry.status = 'abandoned'
                try { Write-SBAccessMetadata $file.FullName $entry } catch { Write-Verbose $_.Exception.Message }
                foreach ($suffix in @('.stop','.renew','.lease')) { [IO.File]::Delete((Join-Path $root ($entry.sessionId+$suffix))) }
            }
        }
        if ($status -in @('closed','failed','expired','abandoned')) {
            $ts = if ($entry.ContainsKey('heartbeat')) { [DateTimeOffset]::Parse($entry.heartbeat) } else { [DateTimeOffset]$file.LastWriteTimeUtc }
            if ($MaxAgeMinutes -le 0 -or $ts -le $cutoff) {
                foreach ($suffix in @('.json','.stop','.renew','.lease')) {
                    $p = Join-Path $root ($entry.sessionId+$suffix)
                    if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) }
                }
                $removedCount++
            }
        }
    }
    $removedCount
}

function Assert-SBSession($Config, [string]$SessionId, [switch]$AllowRead) {
    Test-SBSessionId $SessionId
    $entry = @(Get-SBAccessStatus $Config | Where-Object sessionId -eq $SessionId)
    $modes = if ($AllowRead) { @('Read','Write') } else { @('Write') }
    if ($entry.Count -ne 1 -or $entry[0].status -ne 'active' -or $entry[0].mode -notin $modes) { throw (New-SBError $(if ($AllowRead) { 'access.session.missing' } else { 'access.session.missing.write' })) }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($entry[0].computer -ne [Environment]::MachineName -or $entry[0].user -ne $user -or $entry[0].workstationId -ne $Config.workstationId) { throw (New-SBError 'access.session.foreign') }
    $entry[0]
}

function Enter-SBOperation($Config, [string]$SessionId, [switch]$ReadOnly, [int]$WaitMs = -1, [switch]$ReconcileWorkstation, [switch]$LockOnly, [string]$Scope) {
    # -LockOnly: writer queue and lock only (no workstation registry or guard), for writers outside the brain and on inactive workstations.
    # -Scope (#476): per-dossier writer for the key from Get-SBScopeKey; it takes the dossier's own writer.lock and operation.lock and
    # shares scope.gate with other dossiers, so two dossiers write in parallel. Without -Scope the writer is global and excludes them all.
    $result = @{ writer=$null; operation=$null; metadata=$null; ownerSessionId=$null; config=$Config; concurrentWriter=$false; pendingTransaction=$null; previousGuard=(Get-SBWriteGuard) }
    $waitTotal = Get-SBLockWaitMs $Config $WaitMs
    try {
        if (!(Test-Path -LiteralPath $Config.coordinationRoot)) {
            if ($ReadOnly) { return $result }
            Assert-SBPlainPath $Config.coordinationRoot
            [IO.Directory]::CreateDirectory($Config.coordinationRoot) | Out-Null
        }
        $writerPath = Join-Path $Config.coordinationRoot 'writer.lock'
        if ($ReadOnly) {
            # Reads take no blocking locks (avoiding writer starvation): report an active writer or pending transaction as a warning.
            if ($Config -is [Collections.IDictionary] -and $Config.ContainsKey('brainRoot')) { $result.pendingTransaction = Get-SBPendingTransaction $Config.brainRoot $Scope }
            if ($SessionId) {
                $session = Assert-SBSession $Config $SessionId -AllowRead
                if (($session.mode -eq 'Read' -or ($session.ContainsKey('exclusive') -and !$session.exclusive)) -and (Test-Path -LiteralPath $writerPath)) {
                    try { $probe = [IO.File]::Open($writerPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose() }
                    catch [IO.IOException] { $result.concurrentWriter = $true }
                }
            } elseif (Test-Path -LiteralPath $writerPath) {
                try { $probe = [IO.File]::Open($writerPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose() }
                catch [IO.IOException] { $result.concurrentWriter = $true }
            }
        } else {
            $exclusiveSession=$false
            if ($SessionId) {
                $session=Assert-SBSession $Config $SessionId
                # Old running sessions held writer.lock; preserve their contract until End.
                $exclusiveSession=(!$session.ContainsKey('exclusive') -or [bool]$session.exclusive)
                # A session that holds one repository's lock covers only that repository: any other scope, and the global one, locks normally.
                if($exclusiveSession -and $session.ContainsKey('scope') -and $session.scope -and $session.scope -cne $Scope){$exclusiveSession=$false}
            }
            $scopeRoot = Get-SBCoordinationScopeRoot $Config $Scope
            if ($Scope) {
                Assert-SBPlainPath $scopeRoot
                [IO.Directory]::CreateDirectory($scopeRoot) | Out-Null
                $writerPath = Join-Path $scopeRoot 'writer.lock'
            }
            if (!$exclusiveSession) {
                Assert-SBPlainPath $writerPath
                $onWait = { [Console]::Error.WriteLine('SecondBrain: scrittura occupata, attesa fino a ' + [int]($waitTotal / 1000) + ' s. Titolare: ' + (Get-SBOperationOwnerText $Config $Scope)) }.GetNewClosure()
                $result.writer = Open-SBWriterLock $Config $writerPath $waitTotal $onWait $Scope
                $result.metadata = Join-Path $scopeRoot 'operation-owner.json'
                $result.ownerSessionId = (New-SBId)
                Write-SBAccessMetadata $result.metadata @{sessionId=$result.ownerSessionId;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;computer=[Environment]::MachineName;processId=$PID;client='SecondBrain script';repository=(Get-SBBrainIdentity $Config.brainRoot);workstationId=$Config.workstationId;path=$Config.brainRoot;mode='Write';heartbeat=(Get-SBNow).ToString('o')}
            }
            $opPath = Join-Path $scopeRoot 'operation.lock'
            Assert-SBPlainPath $opPath
            $result.operation = Open-SBLockFile $opPath ([IO.FileMode]::OpenOrCreate) ([IO.FileAccess]::ReadWrite) ([IO.FileShare]::None) $waitTotal
            if ($LockOnly) { return $result }
            # Registration prevents two workstations from accidentally sharing an ID or baseline.
            $registryPath = Join-Path $Config.coordinationRoot 'workstations.json'
            # Dossier writers run in parallel, so the registry check and its rare write are serialized by a short lock of their own.
            $registryLock = Open-SBLockFile (Join-Path $Config.coordinationRoot 'registry.lock') ([IO.FileMode]::OpenOrCreate) ([IO.FileAccess]::ReadWrite) ([IO.FileShare]::None) $waitTotal
            try {
            $registry = Read-SBJson $registryPath @{}
            $identity = [Environment]::MachineName+'|'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $station = @{identity=$identity;runtimeRoot=$Config.runtimeRoot;backupRoot=$Config.backupRoot;repositoryRoot=$Config.repositoryRoot}
            $known = $null
            if ($registry.ContainsKey($Config.workstationId)) {
                $known = $registry[$Config.workstationId]
                if ($known.identity -cne $identity) { throw (New-SBError 'access.station.identity') }
            }
            foreach ($key in $registry.Keys) {
                if ($key -ne $Config.workstationId -and ($registry[$key].runtimeRoot -ieq $Config.runtimeRoot -or $registry[$key].backupRoot -ieq $Config.backupRoot)) { throw (New-SBError 'access.station.roots') }
            }
            # Same identity with different paths (moved folder, UNC alias, accidentally shared baseline): explicit confirmation required.
            # Aliases of the same path (case, mapped drive, UNC with FQDN) are not relocations.
            $moved = $known -and !((Test-SBSamePath $known.runtimeRoot $station.runtimeRoot) -and (Test-SBSamePath $known.backupRoot $station.backupRoot) -and (Test-SBSamePath $known.repositoryRoot $station.repositoryRoot))
            if ($moved -and !$ReconcileWorkstation) { throw (New-SBError 'access.station.moved' @($Config.workstationId,$known.repositoryRoot,$station.repositoryRoot)) }
            if (!$known -or $moved) { $registry[$Config.workstationId]=$station; Write-SBAccessMetadata $registryPath $registry }
            } finally { $registryLock.Dispose() }
            # The closure cannot see private module functions: capture the command before GetNewClosure().
            $assertSession=${function:Assert-SBSession}
            $writeGuard={
                if($SessionId){& $assertSession $Config $SessionId|Out-Null}
                # Actual I/O on the shared handle detects loss of coordination.
                $result.operation.Position=0;$result.operation.WriteByte(1);$result.operation.Flush($true)
                if($result.writer){$result.writer.Position=0;$result.writer.WriteByte(1);$result.writer.Flush($true)}
            }.GetNewClosure()
            Set-SBWriteGuard $writeGuard
        }
        return $result
    } catch {
        Exit-SBOperation $result
        $base = $_.Exception.GetBaseException()
        if ($base -is [IO.IOException] -and ($base.HResult -band 0xffff) -in @(32, 33)) {
            $description = Get-SBOperationOwnerText $Config $Scope
            throw (New-SBError 'access.busy' @([int]($waitTotal / 1000),$description) ([IO.IOException]) 0 $_.Exception)
        }
        throw
    }
}

function Exit-SBOperation($Operation) {
    if (!$Operation) { return }
    $previousGuard=if($Operation.ContainsKey('previousGuard')){$Operation.previousGuard}else{$null}
    Set-SBWriteGuard $previousGuard
    if ($Operation.operation) { $Operation.operation.Dispose() }
    # Remove the owner file only if it is still the file written by this operation.
    if ($Operation.metadata -and [IO.File]::Exists($Operation.metadata)) {
        $recorded = try { Read-SBJson $Operation.metadata @{} } catch { @{} }
        if (!$Operation.ownerSessionId -or ($recorded.ContainsKey('sessionId') -and $recorded.sessionId -eq $Operation.ownerSessionId)) { [IO.File]::Delete($Operation.metadata) }
    }
    if ($Operation.writer) { Close-SBWriterLock $Operation.writer }
}

Export-ModuleMember -Function @(
    'Assert-SBSession',
    'Get-SBPendingTransaction',
    'Format-SBPendingTransaction',
    'Get-SBLockWaitMs',
    'Read-SBConfiguration',
    'Write-SBAccessMetadata',
    'Test-SBSessionId',
    'Open-SBLockFile',
    'Test-SBBusyError',
    'Open-SBWriterLock',
    'Close-SBWriterLock',
    'Get-SBQueueStatus',
    'Get-SBCoordinationScopeRoot',
    'Write-SBReadWarnings',
    'Get-SBOperationOwnerText',
    'Get-SBAccessStatus',
    'Clear-SBStaleSessions',
    'Enter-SBOperation',
    'Exit-SBOperation'
)
