#requires -Version 7.5
<#
.SYNOPSIS
sb uninstall: removes what SecondBrain installed, and only that.
.DESCRIPTION
Previews by default: lists every item to remove and every item that stays, changes nothing.
-Apply runs the selected steps (default: repositories, launchers, ide-blocks, hooks, environment):
  repositories  sb offboard for every binding: managed blocks and pointers removed, open tasks in TASKS.md, dossier saved in the backup folder first
  launchers     .secondbrain/run-tasks.ps1 removed only when identical to a SecondBrain template
  ide-blocks    managed blocks removed from IDE and checkout instruction files by their markers; every other line is kept; backups are verified
  mcp           the secondbrain server entry removed from the client MCP configuration files (JSON and Codex TOML); backup first, other servers stay, result verified
  hooks         client-hooks.ps1 -Uninstall for Claude Code, Codex and Antigravity
  environment   the SECONDBRAIN_HOME user variable
  data          dossiers under repos/ and workstation/; needs -RemoveData and -Authorization "delete dossiers"
  shared        contents of shared/ (README files stay); same -RemoveData and -Authorization as data
  runtime       the .runtime folder, run last, with every backup this command wrote (they cannot be restored afterwards); needs -RemoveRuntime and -RuntimeAuthorization "delete runtime and backups"
Not removed: the checkout itself.
A scan for remaining markers closes the report.
.EXAMPLE
pwsh -NoProfile -File scripts/uninstall.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/uninstall.ps1 -Apply -Only ide-blocks,launchers
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Only=@('repositories','launchers','ide-blocks','mcp','hooks','environment'),
    [switch]$RemoveData,[string]$Authorization,[switch]$RemoveRuntime,[string]$RuntimeAuthorization,
    [string]$ConfigPath,[string]$SessionId
)
$Only=@($Only|ForEach-Object {$_ -split ','}|ForEach-Object {$_.Trim()}|Where-Object {$_})
$validSteps='repositories','launchers','ide-blocks','mcp','hooks','environment','data','shared','runtime'
$badStep=@($Only|Where-Object {$_ -cnotin $validSteps})
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Uninstall.psm1')
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
if($badStep.Count){throw (New-SBError 'uninstall.step.unknown' @($badStep -join ','))}
$brain=Get-SBBrainRootPath
$config=Read-SBConfiguration $ConfigPath -ReadOnly:(!$Apply)
$stateRoot=Get-SBWorkstationStateRoot $brain (Get-SBHostId)
$ideMap=Read-SBJson (Join-Path $stateRoot 'ide-map.json') @{}
$ides=@(if($ideMap.ContainsKey('ides')){$ideMap.ides}elseif($config.ContainsKey('ides')){$config.ides})
$inventory=Get-SBUninstallInventory $config $brain $ides
$report=[ordered]@{applied=$false;steps=@();inventory=$inventory;residue=@()}
if(!$Apply){ConvertTo-SBJson $report;exit 0}
if(($Only -contains 'data' -or $Only -contains 'shared') -and (!$RemoveData -or $Authorization -cne 'delete dossiers')){throw (New-SBError 'uninstall.data.authorization')}
if($Only -contains 'runtime' -and (!$RemoveRuntime -or $RuntimeAuthorization -cne 'delete runtime and backups')){throw (New-SBError 'uninstall.runtime.authorization')}

$instructionFiles=@(Get-SBUninstallInstructionFiles $config $ides)
$bindings=@($config.bindings)
# One coordinated write session for the whole run: the child scripts (offboard, client-hooks) join it instead of waiting for the writer lock this process would hold.
$ownedSession=$null
if(!$SessionId){$ownedSession=& (Join-Path $PSScriptRoot 'access.ps1') -Start -Mode Write -Client uninstall -ConfigPath $config.configPath|ConvertFrom-Json -AsHashtable;$SessionId=[string]$ownedSession.sessionId}
# Child scripts take the writer lock themselves (inside this session), so they run while this process holds none.
$childSession=$SessionId
if($Only -contains 'repositories'){
    foreach($binding in $bindings){
        $arguments=@('-RepositoryIdentity',[string]$binding.identity,'-Apply')
        if($ConfigPath){$arguments+=@('-ConfigPath',$ConfigPath)}
        if($childSession){$arguments+=@('-SessionId',$childSession)}
        if(!$binding.path -or !(Test-Path -LiteralPath $binding.path)){$arguments+='-Force'}
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'offboard.ps1') @arguments | Out-Null
        $report.steps+=[ordered]@{step='repositories';target=[string]$binding.identity;exitCode=$LASTEXITCODE}
    }
}
$operation=Enter-SBOperation $config $SessionId
try{
    if($Only -contains 'launchers'){
        $template=Join-Path $PSScriptRoot 'templates/run-tasks.launcher.ps1'
        $known=@('4D4725AEB58EAD7EC4327806BE5F68933A248C04328CF526E0160A9DA73D0879')
        if(Test-Path -LiteralPath $template){$known+=Get-SBHash ([IO.File]::ReadAllBytes($template))}
        foreach($binding in $bindings){
            if(!$binding.path){continue}
            $launcher=Join-Path ([string]$binding.path) '.secondbrain/run-tasks.ps1'
            if(!(Test-Path -LiteralPath $launcher -PathType Leaf)){continue}
            $hash=Get-SBFileHash $launcher
            if($hash -in $known){Remove-SBFile $launcher ([string]$binding.path) $hash $config.backupRoot|Out-Null;$report.steps+=[ordered]@{step='launchers';target=$launcher;result='removed'}}
            else{$report.steps+=[ordered]@{step='launchers';target=$launcher;result='kept: differs from every template'}}
        }
    }
    if($Only -contains 'ide-blocks'){
        foreach($file in $instructionFiles){
            if(!(Test-Path -LiteralPath $file -PathType Leaf)){continue}
            $text=[IO.File]::ReadAllText($file,[Text.UTF8Encoding]::new($false))
            if(!(Get-SBUninstallBlockNames $text).Count){continue}
            $remaining=Remove-SBUninstallBlocks $text
            $hash=Get-SBFileHash $file
            $isCheckoutFile=@($bindings|Where-Object {$_.path -and $file.StartsWith(([string]$_.path),[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
            if(!$remaining -and $isCheckoutFile){
                Remove-SBFile $file (Split-Path $file) $hash $config.backupRoot|Out-Null
                $report.steps+=[ordered]@{step='ide-blocks';target=$file;result='removed: only the managed block was in it'}
            }else{
                Write-SBFile $file ([Text.UTF8Encoding]::new($false).GetBytes($(if($remaining){$remaining+"`n"}else{''}))) $hash $config.backupRoot -BackupDirty|Out-Null
                $report.steps+=[ordered]@{step='ide-blocks';target=$file;result='block removed, other text kept'}
            }
        }
    }
    if($Only -contains 'mcp'){
        foreach($file in @(Get-SBUninstallMcpFiles $ides)){
            $text=[IO.File]::ReadAllText($file,[Text.UTF8Encoding]::new($false))
            $updated=Remove-SBMcpEntry $text $file
            if($null -eq $updated){continue}
            $hash=Get-SBFileHash $file
            Write-SBFile $file ([Text.UTF8Encoding]::new($false).GetBytes($updated)) $hash $config.backupRoot -BackupDirty|Out-Null
            if($null -ne (Remove-SBMcpEntry ([IO.File]::ReadAllText($file)) $file)){throw (New-SBError 'uninstall.mcp.verify' @($file))}
            $report.steps+=[ordered]@{step='mcp';target=$file;result='secondbrain server entry removed, other servers kept'}
        }
    }
    if($Only -contains 'environment'){
        [Environment]::SetEnvironmentVariable('SECONDBRAIN_HOME',$null,'User')
        $report.steps+=[ordered]@{step='environment';target='SECONDBRAIN_HOME';result='removed'}
    }
    if($Only -contains 'data'){
        foreach($area in 'repos','workstation'){
            $areaPath=Join-Path $brain $area
            if(!(Test-Path -LiteralPath $areaPath)){continue}
            foreach($child in @(Get-ChildItem -LiteralPath $areaPath -Force|Where-Object Name -ne 'README.md')){
                Remove-Item -LiteralPath $child.FullName -Recurse -Force
                $report.steps+=[ordered]@{step='data';target=$child.FullName;result='removed'}
            }
        }
    }
    if($Only -contains 'shared'){
        $areaPath=Join-Path $brain 'shared'
        if(Test-Path -LiteralPath $areaPath){
            foreach($child in @(Get-ChildItem -LiteralPath $areaPath -Force|Where-Object Name -ne 'README.md')){
                Remove-Item -LiteralPath $child.FullName -Recurse -Force
                $report.steps+=[ordered]@{step='shared';target=$child.FullName;result='removed'}
            }
        }
    }
}finally{Exit-SBOperation $operation}
try{
if($Only -contains 'hooks'){
    foreach($client in 'claude-code','codex','antigravity'){
        $arguments=@('-Uninstall','-Client',$client,'-Apply')
        if($ConfigPath){$arguments+=@('-ConfigPath',$ConfigPath)}
        if($childSession){$arguments+=@('-SessionId',$childSession)}
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'client-hooks.ps1') @arguments | Out-Null
        $report.steps+=[ordered]@{step='hooks';target=$client;exitCode=$LASTEXITCODE}
    }
}
}finally{
    if($ownedSession){& (Join-Path $PSScriptRoot 'access.ps1') -End -SessionId $SessionId -ConfigPath $config.configPath|Out-Null}
}
$report.applied=$true
$report.residue=@(Find-SBUninstallResidue $config $ides)
# Last: the runtime folder holds the lock, the configuration and every backup this command wrote, so nothing may run after it.
if($Only -contains 'runtime'){
    $runtimePath=Join-Path $brain '.runtime'
    if(Test-Path -LiteralPath $runtimePath){
        Remove-Item -LiteralPath $runtimePath -Recurse -Force
        $report.steps+=[ordered]@{step='runtime';target=$runtimePath;result=$(if(Test-Path -LiteralPath $runtimePath){'not removed'}else{'removed'})}
    }
}
ConvertTo-SBJson $report
exit $(if($report.residue.Count){2}else{0})
