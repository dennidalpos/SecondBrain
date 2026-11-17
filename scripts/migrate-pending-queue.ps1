#requires -Version 7.5
<#
.SYNOPSIS
Moves the write queue from the old flat layout to one folder per repository.
.DESCRIPTION
Requests (pending-writes, pending-writes/task-update), receipts (pending-receipts) and retired requests (pending-discarded) move under
the scope key of their repository, the same key as the repository's lock. A request that cannot be read, or a receipt without a
repository, goes to the 'unscoped' folder. Without -Apply the command only lists the moves. With -Apply it takes the global writer
lock (no other writer can run during the move), verifies the SHA-256 of every moved file, and writes a manifest next to the queue so the
move can be undone with -Rollback <manifest>. Run it while no other agent or workstation is writing: a consumer that still runs the old
code does not see the new layout.
.EXAMPLE
pwsh -NoProfile -File scripts/migrate-pending-queue.ps1
pwsh -NoProfile -File scripts/migrate-pending-queue.ps1 -Apply
pwsh -NoProfile -File scripts/migrate-pending-queue.ps1 -Rollback .runtime/access/pending-migration/<id>/manifest.json -Apply
#>
[CmdletBinding()]
param([switch]$Apply,[string]$Rollback,[string]$ConfigPath,[string]$SessionId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'migratequeue.manifest.invalid' = @{ en = 'Invalid or foreign migration manifest: use the manifest written by this command' }
    'migratequeue.verify' = @{ en = 'Moved file differs from its source ({0}): the move was stopped; undo it with -Rollback' }
    'migratequeue.destination.exists' = @{ en = 'Destination already exists, nothing was overwritten: {0}' }
}
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
$brain=(Get-SBBrainRootPath)
$access=Join-Path $brain '.runtime/access'
$readScope={param($path,$field) try{$data=Read-SBJson $path $null;if($data -is [Collections.IDictionary] -and $data.Contains($field) -and $data[$field]){return Get-SBScopeKey ([string]$data[$field])}}catch{Write-Verbose $_.Exception.Message};'unscoped'}
$moves=@()
if(!$Rollback){
    $queue=Join-Path $access 'pending-writes'
    $requestScopes=@{}
    foreach($pair in @(@($queue,''),@((Join-Path $queue 'task-update'),'task-update'))){
        if(![IO.Directory]::Exists($pair[0])){continue}
        foreach($file in @(Get-ChildItem -LiteralPath $pair[0] -File -Filter '*.json')){
            $scope=& $readScope $file.FullName 'repository'
            $requestScopes[$file.BaseName]=$scope
            $destination=if($pair[1]){Join-Path $queue "$scope/task-update/$($file.Name)"}else{Join-Path $queue "$scope/$($file.Name)"}
            $moves+=@{kind='request';from=$file.FullName;to=$destination;scope=$scope}
        }
    }
    $receipts=Join-Path $access 'pending-receipts'
    if([IO.Directory]::Exists($receipts)){
        foreach($file in @(Get-ChildItem -LiteralPath $receipts -File -Filter '*.json')){
            $scope=if($requestScopes.ContainsKey($file.BaseName)){$requestScopes[$file.BaseName]}else{& $readScope $file.FullName 'repository'}
            $moves+=@{kind='receipt';from=$file.FullName;to=(Join-Path $receipts "$scope/$($file.Name)");scope=$scope}
        }
    }
    $discarded=Join-Path $access 'pending-discarded'
    if([IO.Directory]::Exists($discarded)){
        foreach($dir in @(Get-ChildItem -LiteralPath $discarded -Directory|Where-Object {$_.Name -cmatch '^[a-f0-9]{32}$'})){
            $scope=& $readScope (Join-Path $dir.FullName 'discarded.json') 'repository'
            $moves+=@{kind='discarded';from=$dir.FullName;to=(Join-Path $discarded "$scope/$($dir.Name)");scope=$scope}
        }
    }
}else{
    $manifestFull=if([IO.Path]::IsPathRooted($Rollback)){$Rollback}else{Join-Path $brain $Rollback}
    $manifest=Read-SBJson (Assert-SBCentralDataPath $brain $manifestFull) $null
    if(!$manifest -or $manifest.schemaVersion -ne 1 -or !(Test-SBSamePath $manifest.brainRoot $brain)){throw (New-SBError 'migratequeue.manifest.invalid')}
    foreach($move in @($manifest.moves)){$moves+=@{kind=$move.kind;from=$move.to;to=$move.from;scope=$move.scope;sha256=$move.sha256}}
}
$summary=[ordered]@{applied=[bool]$Apply;rollback=[bool]$Rollback;moves=$moves.Count;byScope=@($moves|Group-Object {$_.scope}|ForEach-Object {[ordered]@{scope=$_.Name;count=$_.Count}})}
if(!$Apply){ConvertTo-SBJson $summary;return}
if(!$moves.Count){ConvertTo-SBJson $summary;return}
$config=Read-SBConfiguration $ConfigPath
# The global lock excludes every dossier writer for the whole move: nothing can enqueue or drain while files change folder.
$lock=Enter-SBOperation $config $SessionId
try{
    $done=@()
    $hashOf={param($m) if($m.kind -eq 'discarded'){(Get-ChildItem -LiteralPath $m.from -File -Recurse|Sort-Object FullName|ForEach-Object {Get-SBFileHash $_.FullName}) -join ','}else{Get-SBFileHash $m.from}}
    foreach($move in $moves){
        $digest=& $hashOf $move
        if(Test-Path -LiteralPath $move.to){throw (New-SBError 'migratequeue.destination.exists' @($move.to))}
        Assert-SBPlainPath $move.to
        [IO.Directory]::CreateDirectory((Split-Path $move.to))|Out-Null
        Move-Item -LiteralPath $move.from -Destination $move.to
        $check=& $hashOf @{kind=$move.kind;from=$move.to}
        if($check -cne $digest){throw (New-SBError 'migratequeue.verify' @($move.to))}
        $done+=@{kind=$move.kind;from=$move.from;to=$move.to;scope=$move.scope;sha256=$digest}
    }
    if(!$Rollback){
        $folder=Join-Path $access ('pending-migration/'+(New-SBId))
        [IO.Directory]::CreateDirectory($folder)|Out-Null
        $manifestPath=Join-Path $folder 'manifest.json'
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-SBJson @{schemaVersion=1;brainRoot=$brain;movedAt=(Get-SBNow).ToString('o');moves=$done}),[Text.UTF8Encoding]::new($false))
        $summary.manifest=$manifestPath
    }
    ConvertTo-SBJson $summary
}finally{Exit-SBOperation $lock}
