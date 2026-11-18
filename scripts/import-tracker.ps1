#requires -Version 7.5
[CmdletBinding(DefaultParameterSetName='Prepare')]
param(
    [string]$ConfigPath,[string]$SessionId,
    [Parameter(Mandatory,ParameterSetName='Prepare')][string]$Repository,
    [Parameter(Mandatory,ParameterSetName='Prepare')][string]$SourcePath,
    [Parameter(ParameterSetName='Prepare')][string]$HistoryPath,
    [Parameter(ParameterSetName='Prepare')][string]$ReviewPath,
    [Parameter(ParameterSetName='Prepare')][switch]$Merge,
    [Parameter(ParameterSetName='Prepare')][string]$PlanSha256,
    [Parameter(Mandatory,ParameterSetName='RollbackMerge')][string]$RollbackMerge,
    [Parameter(Mandatory,ParameterSetName='Resume')][string]$ResumeManifest,
    [Parameter(Mandatory,ParameterSetName='Rollback')][string]$RollbackManifest,
    [Parameter(ParameterSetName='Prepare')][Parameter(ParameterSetName='Resume')][switch]$Activate,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
# Writer busy beyond the wait limit: exit 3 (the message identifies the owner).
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TrackerImport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TrackerMerge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'importtracker.source.diverged' = @{ en = 'Source differs from the authoritative tracker' }
    'importtracker.merge.applied' = @{ en = 'Tracker merge applied: {0} tasks added; manifest={1}' }
    'importtracker.merge.uptodate' = @{ en = 'Tracker merge not needed: the dossier tracker already holds the checkout tracker' }
    'importtracker.merge.rolledback' = @{ en = 'Tracker merge rolled back' }
    'importtracker.merge.confirm' = @{ en = 'Merge not applied: confirm the previewed plan with -PlanSha256 {0}' }
    'importtracker.merge.options' = @{ en = '-Merge cannot be combined with -HistoryPath or -ReviewPath' }
}
$config=Read-SBConfiguration $ConfigPath
$lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)
try {
    if($Merge -and ($HistoryPath -or $ReviewPath)){throw (New-SBError 'importtracker.merge.options')}
    if($RollbackMerge){
        if(!$Apply){ConvertTo-SBJson (Read-SBTrackerMergeManifest $config $RollbackMerge);exit 0}
        Restore-SBTrackerMerge $config $RollbackMerge;Get-SBMessage 'importtracker.merge.rolledback';exit 0
    }
    if($Merge){
        $area=@(Get-SBParaEntities $config.brainRoot $config.allowedOwners|Where-Object {(Test-SBRepoDossier $_) -and !$_.archived -and $_.status -eq 'active' -and $_.repository -ceq $Repository})
        if($area.Count -ne 1){throw (New-SBError 'trackerimport.area.ambiguous')}
        if(!$Apply){
            $plan=Get-SBTrackerMergePlan $config.brainRoot $Repository (Resolve-SBParaPath $config.brainRoot $area[0].path) $SourcePath
            ConvertTo-SBJson (@{mode='merge-preview'}+$plan.summary);exit 0
        }
        if(!$PlanSha256){
            $plan=Get-SBTrackerMergePlan $config.brainRoot $Repository (Resolve-SBParaPath $config.brainRoot $area[0].path) $SourcePath
            [Console]::Error.WriteLine((Get-SBMessage 'importtracker.merge.confirm' @($plan.summary.planSha256)));exit 2
        }
        $manifest=Invoke-SBTrackerMerge -Config $config -Identity $Repository -SourcePath $SourcePath -PlanSha256 $PlanSha256
        if($manifest){Get-SBMessage 'importtracker.merge.applied' @((Read-SBTrackerMergeManifest $config $manifest).added.Count,$manifest)}else{Get-SBMessage 'importtracker.merge.uptodate'}
        exit 0
    }
    if(!$Apply){
        if($ResumeManifest -or $RollbackManifest){
            $manifestPath=if($ResumeManifest){$ResumeManifest}else{$RollbackManifest}
            $manifest=Read-SBTrackerManifest $config $manifestPath
            ConvertTo-SBJson $manifest
        }
        else{
            $resolved=Resolve-SBTracker -BrainRoot $config.brainRoot -Identity $Repository -CheckoutPath (Split-Path ([IO.Path]::GetFullPath($SourcePath))) -AllowedOwners $config.allowedOwners -AllowUndeclaredImportSource
            if(!$resolved.path -or [IO.Path]::GetFullPath($resolved.path) -ne [IO.Path]::GetFullPath($SourcePath)){throw (New-SBError 'importtracker.source.diverged')}
            $data=ConvertTo-SBTracker -SourcePath $SourcePath -Identity $Repository -HistoryPath $HistoryPath -ReviewPath $ReviewPath
            $null = @(Get-SBParaEntities $config.brainRoot $config.allowedOwners)
            Assert-SBTrackerWriteData $config.brainRoot $Repository $data
            ConvertTo-SBJson @{mode='preview';repository=$Repository;tasks=$data.tasks.Count;review=@($data.tasks|Where-Object status -eq 'unknown'|ForEach-Object id);readiness=@(Get-SBTrackerImportReadiness $data);activationApproved=Test-SBTrackerPolicy $config.brainRoot}
        }
        exit 0
    }
    if($RollbackManifest){Restore-SBTrackerImport $config $RollbackManifest;'Importazione tracker ripristinata';exit 0}
    $arguments=@{Config=$config;Activate=$Activate}
    if($ResumeManifest){$arguments.ManifestPath=$ResumeManifest}else{$arguments.Identity=$Repository;$arguments.SourcePath=$SourcePath;$arguments.HistoryPath=$HistoryPath;$arguments.ReviewPath=$ReviewPath}
    $manifest=Invoke-SBTrackerImport @arguments
    $state=Read-SBTrackerManifest $config $manifest
    'Migrazione tracker: '+$state.phase+'; manifest='+$manifest
    if($state.phase -ne 'completed'){'Fonte precedente ancora autorevole; attivazione separata dopo approvazione';exit 1}
    exit 0
} finally {Exit-SBOperation $lock}
