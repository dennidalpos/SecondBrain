#requires -Version 7.5
<#
.SYNOPSIS
Rolls back a retired or forbidden SecondBrain repository: returns data to the target repository and removes all SecondBrain remnants to protect privacy.
.DESCRIPTION
Without -Apply, previews only and changes nothing.
Requires a write session (Enter-SBOperation, optional -SessionId) and refuses the brain's own dossier.
1. Copies the entire dossier (including history/, snapshots/ and tracker.md) to <TargetRepo>/.secondbrain/ and verifies its hashes. Without a checkout (-Force), saves the dossier in backupRoot (rollback-<id>) before removal.
2. Updates workstation.json (binding removed, repository added to forbiddenRepositories with -Forbid) and state.json.
3. Removes the managed SecondBrain blocks from the target repository's AGENTS.md and, where present, the CLAUDE.md and GEMINI.md pointers.
4. Only then removes the dossier and runtime cache, then no index files are kept.
An error in steps 1-3 leaves the dossier intact: rollback can be repeated.
With -TasksOnly (sb offboard) step 1 is different: the dossier is saved in backupRoot (rollback-<id>) and the checkout only receives TASKS.md with the open tasks, so it matches a fresh clone plus TASKS.md.
.EXAMPLE
pwsh -NoProfile -File scripts/rollback-repo.ps1 -RepositoryIdentity "github.com/my-org/my-project" -Forbid -Apply
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)][string]$RepositoryIdentity,
    [string]$DestinationPath,
    [string]$BrainRoot,
    [string]$ConfigPath,
    [string]$SessionId,
    [switch]$Forbid,
    [switch]$Force,
    [switch]$TasksOnly,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
$brain = if ($BrainRoot) { [IO.Path]::GetFullPath($BrainRoot) } else { Get-SBBrainRootPath }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
# Writer busy beyond the wait limit: exit 3 (the message identifies the owner).
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'rollback.reparse' = @{ en = 'Reparse point in the dossier, rollback refused: {0}' }
    'rollback.hash.copy' = @{ en = 'Hash verification failed in the copy: {0}' }
    'rollback.identity.dossiers' = @{ en = 'Ambiguous identity: {0} dossiers match ''{1}'' ({2}). Give the full repository identity.' }
    'rollback.identity.folders' = @{ en = 'Ambiguous identity: {0} folders match ''{1}'' ({2}). Give the full repository identity.' }
    'rollback.dossier.missing' = @{ en = 'Dossier not found for the identity or name: {0}' }
    'rollback.self.repository' = @{ en = 'Rollback refused: ''{0}'' is the SecondBrain repository itself.' }
    'rollback.checkout.missing' = @{ en = 'Destination checkout not found for {0} (give -DestinationPath or use -Force if the local checkout is removed).' }
    'rollback.self.checkout' = @{ en = 'Rollback refused: the destination checkout is SecondBrain itself.' }
    'rollback.out.start' = @{ en = 'Starting privacy rollback for: {0}' }
    'rollback.out.source' = @{ en = '  Source dossier: {0}' }
    'rollback.out.target' = @{ en = '  Target checkout : {0}' }
    'rollback.out.preview' = @{ en = 'Preview: no changes made. Re-run with -Apply to return the data, update the workstation and delete the dossier.' }
    'rollback.out.copied' = @{ en = '  Copied {0} dossier files -> .secondbrain/ (hashes verified)' }
    'rollback.out.excluded' = @{ en = '  Added .secondbrain/ to .git/info/exclude' }
    'rollback.out.nocheckout' = @{ en = 'Checkout missing: dossier saved in {0} (nothing transferred to the repository).' }
    'rollback.out.forbidden' = @{ en = '  Added to forbiddenRepositories: {0}' }
    'rollback.out.workstation' = @{ en = '  Updated workstation.json' }
    'rollback.out.state' = @{ en = '  Removed managed state for {0}' }
    'rollback.out.block' = @{ en = '  Removed SecondBrain managed block from {0}' }
    'rollback.out.dossier' = @{ en = '  Deleted dossier: {0}' }
    'rollback.out.runtime' = @{ en = '  Deleted runtime directory: {0}' }
    'rollback.out.index' = @{ en = '  Entities checked' }
    'rollback.out.tasks' = @{ en = '  Wrote {0} open tasks -> TASKS.md; dossier saved in {1}' }
    'rollback.out.done' = @{ en = 'Rollback completed successfully for {0}.' }
}

function ConvertTo-RollbackPath([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\','/') }

# Recursively copy the entire dossier, verifying each file hash; reject reparse points.
function Copy-RollbackTree([string]$Source,[string]$Destination) {
    $sourceRoot = ConvertTo-RollbackPath $Source
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File)
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (New-SBError 'rollback.reparse' @($item.FullName)) }
    }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\','/')
        $target = Join-Path $Destination $relative
        [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        if ((Get-SBFileHash $file.FullName) -ne (Get-SBFileHash $target)) { throw (New-SBError 'rollback.hash.copy' @($relative)) }
    }
    $files.Count
}

$config = Read-SBConfiguration $ConfigPath
$workstationConfigPath = Get-SBHostConfigPath $brain
$workstationConfig = Read-SBJson $workstationConfigPath @{}
$operation = Enter-SBOperation $config $SessionId
try {
    # 1. Find the dossier in repos or legacy repos (case-sensitive comparisons; always reject ambiguity).
    $entities = @(Get-SBParaEntities $brain @())
    $matchedEntities = @($entities | Where-Object {
        (Test-SBRepoDossier $_) -and (
            $_.repository -ceq $RepositoryIdentity -or
            ($_.path -and ($_.path -split '[\\/]')[-1] -ceq $RepositoryIdentity) -or
            ($_.title -and $_.title -ceq $RepositoryIdentity)
        )
    })
    if ($matchedEntities.Count -gt 1) {
        throw (New-SBError 'rollback.identity.dossiers' @($matchedEntities.Count, $RepositoryIdentity, (($matchedEntities | ForEach-Object path) -join ', ')))
    }

    $dossierPath = $null
    $dossierRelative = $null
    $resolvedIdentity = $RepositoryIdentity

    if ($matchedEntities.Count -gt 0) {
        $target = $matchedEntities[0]
        $dossierRelative = $target.path
        $dossierPath = Join-Path $brain $dossierRelative
        if ($target.repository) { $resolvedIdentity = $target.repository }
    } else {
        $folderMatches = @()
        foreach ($areasRelative in @('repos', 'repos')) {
        $areasDir = Join-Path $brain $areasRelative
        if (Test-Path -LiteralPath $areasDir) {
            foreach ($dir in Get-ChildItem -LiteralPath $areasDir -Directory) {
                $repoMeta = Join-Path $dir.FullName 'repository.json'
                if (Test-Path -LiteralPath $repoMeta) {
                    $meta = Read-SBJson $repoMeta @{}
                    if (($meta.ContainsKey('identity') -and $meta.identity -ceq $RepositoryIdentity) -or $dir.Name -ceq $RepositoryIdentity) {
                        $folderMatches += @{ path = $dir.FullName; relative = $areasRelative + '/' + $dir.Name; identity = $(if ($meta.ContainsKey('identity')) { [string]$meta.identity } else { '' }) }
                    }
                }
            }
        }
        }
        if ($folderMatches.Count -gt 1) {
            throw (New-SBError 'rollback.identity.folders' @($folderMatches.Count, $RepositoryIdentity, (($folderMatches | ForEach-Object { $_.relative }) -join ', ')))
        }
        if ($folderMatches.Count -eq 1) {
            $dossierPath = $folderMatches[0].path
            $dossierRelative = $folderMatches[0].relative
            if ($folderMatches[0].identity) { $resolvedIdentity = $folderMatches[0].identity }
        }
    }

    if (!$dossierPath -or !(Test-Path -LiteralPath $dossierPath)) {
        throw (New-SBError 'rollback.dossier.missing' @($RepositoryIdentity))
    }

    # The brain's own dossier can never be returned or deleted.
    $brainIdentity = Get-SBBrainIdentity $brain
    if (($brainIdentity -and $resolvedIdentity -ceq $brainIdentity) -or (ConvertTo-RollbackPath $dossierPath) -ieq (ConvertTo-RollbackPath $brain)) {
        throw (New-SBError 'rollback.self.repository' @($resolvedIdentity))
    }

    # 2. Resolve the target checkout.
    $checkoutPath = $DestinationPath
    if (!$checkoutPath -and $workstationConfig.ContainsKey('bindings')) {
        $binding = @($workstationConfig.bindings | Where-Object { $_.identity -ceq $resolvedIdentity -or ($_.PSObject.Properties['dossier'] -and $_.dossier -ceq $dossierRelative) }) | Select-Object -First 1
        if ($binding) { $checkoutPath = $binding.path }
    }
    $hasCheckout = [bool]($checkoutPath -and (Test-Path -LiteralPath $checkoutPath))
    if (!$hasCheckout -and !$Force) {
        throw (New-SBError 'rollback.checkout.missing' @($RepositoryIdentity))
    }
    if ($hasCheckout -and (ConvertTo-RollbackPath $checkoutPath) -ieq (ConvertTo-RollbackPath $brain)) {
        throw (New-SBError 'rollback.self.checkout')
    }

    Write-Host (Get-SBMessage 'rollback.out.start' @($resolvedIdentity)) -ForegroundColor Cyan
    Write-Host (Get-SBMessage 'rollback.out.source' @($dossierPath))
    Write-Host (Get-SBMessage 'rollback.out.target' @($checkoutPath))

    if (!$Apply) {
        Write-Host (Get-SBMessage 'rollback.out.preview') -ForegroundColor Yellow
        return @{ identity = $resolvedIdentity; checkout = $checkoutPath; dossierDeleted = $null; forbidden = [bool]$Forbid; status = 'preview' }
    }
    if (!$PSCmdlet.ShouldProcess($dossierPath, 'Rollback: restituzione dei dati, aggiornamento postazione ed eliminazione del dossier SecondBrain')) {
        return @{ identity = $resolvedIdentity; checkout = $checkoutPath; dossierDeleted = $null; forbidden = [bool]$Forbid; status = 'skipped' }
    }

    # 3. Transfer the whole dossier to the target repository, or a central backup if the checkout is absent.
    $transferred = 0
    $backupPath = $null
    if ($TasksOnly) {
        # Offboard: the full dossier goes to the central backup; the checkout only gets the open tasks.
        $backupPath = Join-Path $config.backupRoot ('rollback-' + (New-SBId))
        $transferred = Copy-RollbackTree $dossierPath (Join-Path $backupPath 'dossier')
        if ($hasCheckout) {
            $trackerFile = Join-Path $dossierPath 'tracker.json'
            $tracker = Read-SBJson $trackerFile @{ tasks = @() }
            $open = @(@($tracker.tasks) | Where-Object { $_.status -cnotin @('done', 'cancelled', 'closed') } | Sort-Object { [int]$_.seq })
            $lines = @('# Open tasks', '', ('Exported from the SecondBrain tracker of ' + $resolvedIdentity + ' on ' + (Get-SBNow).ToString('yyyy-MM-dd') + '.', ''))
            foreach ($task in $open) { $lines += ('- [{0}] {1} ({2})' -f $(if ($task.priority) { $task.priority } else { '-' }), $task.title, $task.status) }
            $tasksPath = Join-Path $checkoutPath 'TASKS.md'
            Write-SBFile $tasksPath ([Text.UTF8Encoding]::new($false).GetBytes((($lines -join "`n") + "`n"))) (Get-SBFileHash $tasksPath) $config.backupRoot | Out-Null
            Write-Information (Get-SBMessage 'rollback.out.tasks' @($open.Count, $backupPath)) -InformationAction Continue
        }
    } elseif ($hasCheckout) {
        $transferred = Copy-RollbackTree $dossierPath (Join-Path $checkoutPath '.secondbrain')
        Write-Host (Get-SBMessage 'rollback.out.copied' @($transferred)) -ForegroundColor Green
        $gitDir = Join-Path $checkoutPath '.git'
        if (Test-Path -LiteralPath $gitDir) {
            $excludeFile = Join-Path $gitDir 'info/exclude'
            if (Test-Path -LiteralPath $excludeFile) {
                $excludeContent = [IO.File]::ReadAllText($excludeFile)
                if ($excludeContent -notmatch '(?m)^\.secondbrain/?$') {
                    [IO.File]::AppendAllText($excludeFile, "`n.secondbrain/`n", [Text.Encoding]::UTF8)
                    Write-Host (Get-SBMessage 'rollback.out.excluded') -ForegroundColor Green
                }
            }
        }
    } else {
        $backupPath = Join-Path $config.backupRoot ('rollback-' + (New-SBId))
        $transferred = Copy-RollbackTree $dossierPath (Join-Path $backupPath 'dossier')
        Write-Warning (Get-SBMessage 'rollback.out.nocheckout' @($backupPath))
    }

    # 4. Update workstation.json and state.json before any deletion: failure here leaves the dossier intact.
    $bindings = @()
    if ($workstationConfig.ContainsKey('bindings')) {
        $bindings = @($workstationConfig.bindings | Where-Object { $_.identity -ne $resolvedIdentity -and (!$_.PSObject.Properties['dossier'] -or $_.dossier -ne $dossierRelative) })
        $workstationConfig.bindings = $bindings
    }
    $forbidden = @()
    if ($workstationConfig.ContainsKey('forbiddenRepositories')) { $forbidden = @($workstationConfig.forbiddenRepositories) }
    if ($Forbid) {
        $alreadyForbidden = $forbidden | Where-Object { $_.identity -eq $resolvedIdentity -or ($checkoutPath -and $_.path -eq $checkoutPath) }
        if (!$alreadyForbidden) {
            $forbidden += @{
                identity = $resolvedIdentity
                path = if ($checkoutPath) { $checkoutPath } else { '' }
                reason = 'user-requested-rollback'
                forbiddenAt = (Get-SBNow).ToString('o')
            }
            Write-Host (Get-SBMessage 'rollback.out.forbidden' @($resolvedIdentity)) -ForegroundColor Magenta
        }
    }
    $workstationConfig.forbiddenRepositories = $forbidden
    Write-SBFile $workstationConfigPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $workstationConfig))) (Get-SBFileHash $workstationConfigPath) $config.localStateBackupRoot | Out-Null
    Write-Host (Get-SBMessage 'rollback.out.workstation') -ForegroundColor Green

    $statePath = Join-Path $config.localStateRoot 'state.json'
    $stateSource = if (Test-Path -LiteralPath $statePath -PathType Leaf) { $statePath } else { Join-Path $config.runtimeRoot 'state.json' }
    if ($checkoutPath -and (Test-Path -LiteralPath $stateSource -PathType Leaf)) {
        $state = Read-SBJson $stateSource @{ managed = @{} }
        $keys = @([IO.Path]::GetFullPath((Join-Path $checkoutPath 'AGENTS.md')) + '|repository') + @('CLAUDE.md', 'GEMINI.md' | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $checkoutPath $_)) + '|pointer' })
        foreach ($key in $keys) {
            if ($state.managed.ContainsKey($key)) {
                $state.managed.Remove($key)
                Write-SBFile $statePath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $state))) (Get-SBFileHash $statePath) $config.localStateBackupRoot | Out-Null
                Write-Host (Get-SBMessage 'rollback.out.state' @($key)) -ForegroundColor Green
            }
        }
    }

    # 5. Clean AGENTS.md in the target repository.
    if ($hasCheckout) {
        $agentsPath = Join-Path $checkoutPath 'AGENTS.md'
        if (Test-Path -LiteralPath $agentsPath) {
            $content = [IO.File]::ReadAllText($agentsPath, [Text.UTF8Encoding]::new($false))
            $pattern = '(?s)\r?\n?<!-- secondbrain:repository:begin -->.*?<!-- secondbrain:repository:end -->\r?\n?'
            if ($content -match $pattern) {
                $newContent = ($content -replace $pattern, "`n").Trim() + "`n"
                # Write with hash checking and a verified backup (restorable with restore-managed.ps1).
                Write-SBFile $agentsPath ([Text.UTF8Encoding]::new($false).GetBytes($newContent)) (Get-SBFileHash $agentsPath) $config.backupRoot -BackupDirty | Out-Null
                Write-Host (Get-SBMessage 'rollback.out.block' @($agentsPath)) -ForegroundColor Green
            }
        }
        # Pointer files (CLAUDE.md, GEMINI.md): remove only the managed block; the file goes only if nothing else remains.
        foreach ($pointer in @('CLAUDE.md', 'GEMINI.md')) {
            $pointerPath = Join-Path $checkoutPath $pointer
            if (!(Test-Path -LiteralPath $pointerPath)) { continue }
            $content = [IO.File]::ReadAllText($pointerPath, [Text.UTF8Encoding]::new($false))
            $pointerPattern = '(?s)\r?\n?<!-- secondbrain:pointer:begin -->.*?<!-- secondbrain:pointer:end -->\r?\n?'
            if ($content -notmatch $pointerPattern) { continue }
            $remaining = ($content -replace $pointerPattern, "`n").Trim()
            if ($remaining) {
                Write-SBFile $pointerPath ([Text.UTF8Encoding]::new($false).GetBytes($remaining + "`n")) (Get-SBFileHash $pointerPath) $config.backupRoot -BackupDirty | Out-Null
            } else {
                Remove-SBFile $pointerPath $checkoutPath (Get-SBFileHash $pointerPath) $config.backupRoot | Out-Null
            }
            Write-Host (Get-SBMessage 'rollback.out.block' @($pointerPath)) -ForegroundColor Green
        }
    }

    # 6. Delete after transfer and workstation update.
    Remove-Item -LiteralPath $dossierPath -Recurse -Force
    Write-Host (Get-SBMessage 'rollback.out.dossier' @($dossierPath)) -ForegroundColor Yellow
    if ($resolvedIdentity) {
        $repoRuntimeDir = Join-Path $workstationConfig.runtimeRoot ('repositories/' + (Get-SBTextHash $resolvedIdentity).Substring(0,24).ToLowerInvariant())
        if (Test-Path -LiteralPath $repoRuntimeDir) {
            Remove-Item -LiteralPath $repoRuntimeDir -Recurse -Force
            Write-Host (Get-SBMessage 'rollback.out.runtime' @($repoRuntimeDir)) -ForegroundColor Yellow
        }
    }

    # 7. Re-read the entities (there are no index files).
    Update-SBParaIndex $config | Out-Null
    Write-Host (Get-SBMessage 'rollback.out.index') -ForegroundColor Green

    Write-Host (Get-SBMessage 'rollback.out.done' @($resolvedIdentity)) -ForegroundColor Green
    return @{
        identity = $resolvedIdentity
        checkout = $checkoutPath
        dossierDeleted = $dossierPath
        filesTransferred = $transferred
        backup = $backupPath
        forbidden = [bool]$Forbid
        status = 'completed'
    }
} finally { Exit-SBOperation $operation }
