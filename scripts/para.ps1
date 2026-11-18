#requires -Version 7.5
[CmdletBinding(DefaultParameterSetName='Check')]
param(
    [string]$ConfigPath,[string]$SessionId,
    [string]$BackupRoot,
    [Parameter(ParameterSetName='Check')][switch]$Check,
    [Parameter(Mandatory,ParameterSetName='Index')][switch]$BuildIndex,
    [Parameter(Mandatory,ParameterSetName='Suggest')][switch]$SuggestArchive,
    [Parameter(Mandatory,ParameterSetName='New')][switch]$NewProject,
    [Parameter(Mandatory,ParameterSetName='Resource')][switch]$NewResource,
    [Parameter(Mandatory,ParameterSetName='Area')][switch]$NewArea,
    [Parameter(Mandatory,ParameterSetName='Status')][switch]$SetStatus,
    [Parameter(Mandatory,ParameterSetName='New')][Parameter(Mandatory,ParameterSetName='Resource')][Parameter(Mandatory,ParameterSetName='Area')][ValidatePattern('^[a-z][a-z0-9-]{0,95}$')][string]$Id,
    [Parameter(Mandatory,ParameterSetName='New')][Parameter(Mandatory,ParameterSetName='Resource')][Parameter(Mandatory,ParameterSetName='Area')][string]$Title,
    [Parameter(ParameterSetName='New')][string[]]$Areas=@(),
    [Parameter(Mandatory,ParameterSetName='New')][Parameter(Mandatory,ParameterSetName='Resource')][Parameter(Mandatory,ParameterSetName='Area')][string]$Objective,
    [Parameter(Mandatory,ParameterSetName='New')][string[]]$Acceptance,
    [Parameter(Mandatory,ParameterSetName='Status')][ValidateSet('active','completed','cancelled','retired')][string]$Status,
    [Parameter(Mandatory,ParameterSetName='Customer')][switch]$SetCustomer,
    [Parameter(ParameterSetName='Customer')][string]$Customer,
    [Parameter(ParameterSetName='Customer')][switch]$Clear,
    [Parameter(Mandatory,ParameterSetName='GitUpdate')][switch]$SetGitUpdate,
    [Parameter(Mandatory,ParameterSetName='GitUpdate')][ValidateSet('commit-push-main','branch-pr','none')][string]$GitMode,
    [Parameter(ParameterSetName='GitUpdate')][string]$GitBranch,
    [Parameter(ParameterSetName='GitUpdate')][switch]$Confirmed,
    [Parameter(ParameterSetName='Customer')][Parameter(ParameterSetName='GitUpdate')][switch]$Apply,
    [Parameter(Mandatory,ParameterSetName='Customer')][Parameter(Mandatory,ParameterSetName='GitUpdate')][string[]]$Only,
    [Parameter(Mandatory,ParameterSetName='Archive')][switch]$Archive,
    [Parameter(Mandatory,ParameterSetName='Restore')][switch]$Restore,
    [Parameter(Mandatory,ParameterSetName='Archive')][Parameter(Mandatory,ParameterSetName='Restore')][Parameter(Mandatory,ParameterSetName='Status')][string]$EntityId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
# Writer busy beyond the wait limit: exit 3 (the message identifies the owner).
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TrackerImport.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'paracli.policy.invalid' = @{ en = 'Invalid shared policy: config/shared.json' }
    'paracli.project.fields' = @{ en = 'Title, objective and completion criteria required' }
    'paracli.area.unknown' = @{ en = 'Active repository dossier or area does not exist' }
    'paracli.project.folder' = @{ en = 'Project folder already present' }
    'paracli.resource.fields' = @{ en = 'Title and objective required' }
    'paracli.id.present' = @{ en = 'Identifier already present' }
    'paracli.resource.folder' = @{ en = 'Resource folder already present' }
    'paracli.entity.archived' = @{ en = 'Entity archived: restore it before changing its status' }
    'paracli.status.invalid' = @{ en = 'Invalid status for {0}: allowed {1}' }
    'paracli.status.same' = @{ en = 'Status already set' }
    'paracli.entity.unknown' = @{ en = 'PARA entity does not exist' }
    'paracli.entity.archivedalready' = @{ en = 'Entity already archived' }
    'paracli.entity.activealready' = @{ en = 'Entity already active' }
    'paracli.archive.blocked' = @{ en = 'Status or active Projects prevent archiving' }
    'paracli.destination.exists' = @{ en = 'Destination already exists' }
    'paracli.migrate.plan' = @{ en = 'Migration preview ({0} dossiers): rerun with -Apply to move them to repos' }
    'paracli.migrate.done' = @{ en = 'Migrated {0} dossiers to repos' }
    'paracli.migrate.dirty' = @{ en = 'Dossier cannot be migrated ({0}): {1}' }
    'paracli.customer.required' = @{ en = 'Provide -Customer with a valid name (single line, at most 120 characters) or -Clear' }
    'paracli.customer.none' = @{ en = 'No repository dossier matches -Only' }
    'paracli.customer.plan' = @{ en = 'Customer preview ({0} dossiers): rerun with -Apply to write repository.json (PARA ids and tasks unchanged)' }
    'paracli.customer.done' = @{ en = 'Customer assigned to {0} dossiers; PARA ids, identities and tasks verified unchanged' }
    'paracli.customer.diverged' = @{ en = 'Post-write check failed: identifiers diverge for {0}' }
    'paracli.gitupdate.confirm' = @{ en = 'Writing gitUpdate needs -Confirmed: the owner must explicitly accept this way of updating Git and GitHub' }
    'paracli.gitupdate.plan' = @{ en = 'gitUpdate preview ({0} dossiers): rerun with -Apply -Confirmed to write repository.json (identities and tasks unchanged)' }
    'paracli.gitupdate.done' = @{ en = 'gitUpdate written for {0} dossiers; the runner and delegates still never commit or push' }
    'paracli.tracker.changed' = @{ en = 'Tracker modified while preparing the move' }
}
$config=Read-SBConfiguration $ConfigPath
if(!$BackupRoot){$BackupRoot=$config.backupRoot}
if($config.ContainsKey('mode') -and $config.mode -eq 'portable'){$BackupRoot=Assert-SBCentralDataPath $config.brainRoot $BackupRoot}
if((Read-SBJson (Join-Path $config.brainRoot 'config/shared.json') @{}).schemaVersion -ne 1){throw (New-SBError 'paracli.policy.invalid')}
$writing=$BuildIndex -or $NewProject -or $NewResource -or $NewArea -or $SetStatus -or $Archive -or $Restore -or ($SetCustomer -and $Apply) -or ($SetGitUpdate -and $Apply)
$lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$writing)
try {
    $index=Get-SBParaIndex $config.brainRoot $config.allowedOwners
    if($NewProject){
        if(!$Title.Trim() -or $Title -match '[\r\n]' -or !$Objective.Trim() -or !$Acceptance.Count -or @($Acceptance|Where-Object {![string]$_ -or !([string]$_).Trim()}).Count){throw (New-SBError 'paracli.project.fields')}
        if(@($index.entities|Where-Object id -eq $Id).Count){throw (New-SBError 'paracli.id.present')}
        foreach($area in $Areas){if(!@($index.entities|Where-Object {$_.id -eq $area -and (Test-SBRepoDossier $_) -and !$_.archived -and $_.status -eq 'active'}).Count){throw (New-SBError 'paracli.area.unknown')}}
        $dir=Resolve-SBParaPath $config.brainRoot ('repos/'+$Id)
        if(Test-Path -LiteralPath $dir){throw (New-SBError 'paracli.project.folder')}
        $meta=New-SBParaMetadata $Id 'project' $Title;$meta.areas=@($Areas|Sort-Object -Unique);$meta.trackers=@()
        $brief="# $Title`n`n## Obiettivo`n`n$Objective`n`n## Criteri di completamento`n`n"+(($Acceptance|ForEach-Object {'- '+$_}) -join "`n")+"`n"
        $ops=@(@{path=(Join-Path $dir 'entity.json');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $meta))},@{path=(Join-Path $dir 'brief.md');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes($brief)})
        Invoke-SBParaTransaction $ops $BackupRoot $config.brainRoot
    }elseif($NewResource){
        if(!$Title.Trim() -or $Title -match '[\r\n]' -or !$Objective.Trim()){throw (New-SBError 'paracli.resource.fields')}
        if(@($index.entities|Where-Object id -eq $Id).Count){throw (New-SBError 'paracli.id.present')}
        $dir=Resolve-SBParaPath $config.brainRoot ('shared/'+$Id)
        if(Test-Path -LiteralPath $dir){throw (New-SBError 'paracli.resource.folder')}
        $meta=New-SBParaMetadata $Id 'resource' $Title
        $brief="# $Title`n`n## Obiettivo`n`n$Objective`n"
        $ops=@(@{path=(Join-Path $dir 'entity.json');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $meta))},@{path=(Join-Path $dir 'brief.md');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes($brief)})
        Invoke-SBParaTransaction $ops $BackupRoot $config.brainRoot
    }elseif($NewArea){
        # A PARA area is an ongoing responsibility without an end date (workstation/<id>); repository dossiers stay in repos.
        if(!$Title.Trim() -or $Title -match '[\r\n]' -or !$Objective.Trim()){throw (New-SBError 'paracli.resource.fields')}
        if(@($index.entities|Where-Object id -eq $Id).Count){throw (New-SBError 'paracli.id.present')}
        $dir=Resolve-SBParaPath $config.brainRoot ('workstation/'+$Id)
        if(Test-Path -LiteralPath $dir){throw (New-SBError 'paracli.resource.folder')}
        $meta=New-SBParaMetadata $Id 'area' $Title
        $brief="# $Title`n`n## Obiettivo`n`n$Objective`n"
        $ops=@(@{path=(Join-Path $dir 'entity.json');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $meta))},@{path=(Join-Path $dir 'brief.md');expected='absent';bytes=[Text.Encoding]::UTF8.GetBytes($brief)})
        Invoke-SBParaTransaction $ops $BackupRoot $config.brainRoot
    }elseif($SetStatus){
        $matches=@($index.entities|Where-Object id -eq $EntityId)
        if($matches.Count -ne 1){throw (New-SBError 'paracli.entity.unknown')};$item=$matches[0]
        $allowed=@{project=@('active','completed','cancelled');area=@('active','retired');resource=@('active','retired')}[$item.kind]
        if($Status -notin $allowed){throw (New-SBError 'paracli.status.invalid' @($item.kind, ($allowed -join ', ')))}
        if($item.status -eq $Status){throw (New-SBError 'paracli.status.same')}
        $metaPath=Join-Path (Resolve-SBParaPath $config.brainRoot $item.path) 'entity.json'
        $m=Read-SBJson $metaPath $null;$m.status=$Status
        Invoke-SBParaTransaction @(,@{path=$metaPath;expected=(Get-SBFileHash $metaPath);bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))}) $BackupRoot $config.brainRoot
    }elseif($SetCustomer){
        # Customer grouping: only the "customer" field of repository.json changes (PARA id, repository identity, tracker and folder stay as they are).
        # Preview by default; -Apply writes every selected dossier in one transaction and verifies the identifiers afterwards.
        $wanted=if($Clear){''}else{([string]$Customer).Trim()}
        if(!$Clear -and (!$wanted -or $wanted.Length -gt 120 -or $wanted -match '[\p{Cc}\p{Cf}]')){throw (New-SBError 'paracli.customer.required')}
        if($Clear -and $Customer){throw (New-SBError 'paracli.customer.required')}
        $snapshot={
            param($entities)
            @($entities|Where-Object {(Test-SBRepoDossier $_) -and $_.id -in $selectedIds}|Sort-Object id|ForEach-Object {
                $dir=Resolve-SBParaPath $config.brainRoot $_.path
                $record=Read-SBJson (Join-Path $dir 'repository.json') @{}
                $trackerPath=if($record.ContainsKey('tracker') -and $record.tracker.location -eq 'dossier' -and $record.tracker.path){Join-Path $dir ([string]$record.tracker.path)}else{''}
                $tracker=if($trackerPath -and (Test-Path -LiteralPath $trackerPath -PathType Leaf)){Read-SBJson $trackerPath @{}}else{@{}}
                $ids=if($tracker.ContainsKey('tasks')){@($tracker.tasks|ForEach-Object {[string]$_.id}|Sort-Object)}else{@()}
                [ordered]@{id=$_.id;repository=$_.repository;path=$_.path;paraHash=(Get-SBFileHash (Join-Path $dir 'entity.json'));trackerHash=$(if($trackerPath){Get-SBFileHash $trackerPath}else{''});taskIds=($ids -join ',')}
            })
        }
        # With -File an array is passed as one string: accept comma-separated values too.
        $Only=@($Only|ForEach-Object {$_ -split ','}|ForEach-Object {$_.Trim()}|Where-Object {$_})
        $selected=@($index.entities|Where-Object {(Test-SBRepoDossier $_) -and ($_.id -in $Only -or $_.repository -in $Only)})
        if(!$selected.Count){throw (New-SBError 'paracli.customer.none')}
        $selectedIds=@($selected|ForEach-Object id)
        $before=& $snapshot $index.entities
        $plan=@(foreach($item in ($selected|Sort-Object id)){
            $path=Join-Path (Resolve-SBParaPath $config.brainRoot $item.path) 'repository.json'
            $record=Read-SBJson $path $null
            if($wanted){$record.customer=$wanted}else{[void]$record.Remove('customer')}
            $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))
            $previous=Get-SBFileHash $path
            [ordered]@{id=$item.id;repository=$item.repository;path=$item.path;archived=$item.archived;customerBefore=$item.customer;customerAfter=$wanted;changed=($previous -ne (Get-SBHash $bytes));file=$path;expected=$previous;bytes=$bytes}
        })
        $view=@($plan|ForEach-Object {[ordered]@{id=$_.id;repository=$_.repository;path=$_.path;archived=$_.archived;customerBefore=$_.customerBefore;customerAfter=$_.customerAfter;changed=$_.changed}})
        if(!$Apply){
            ConvertTo-SBJson @{apply=$false;dossiers=$view;identifiers=@($before|ForEach-Object {[ordered]@{id=$_.id;repository=$_.repository;tasks=$(if($_.taskIds){($_.taskIds -split ',').Count}else{0})}})}
            (Get-SBMessage 'paracli.customer.plan' @($plan.Count))
        }else{
            $ops=@($plan|Where-Object changed|ForEach-Object {@{path=$_.file;expected=$_.expected;bytes=$_.bytes}})
            if($ops.Count){Invoke-SBParaTransaction $ops $BackupRoot $config.brainRoot}
            $after=& $snapshot (Get-SBParaEntities $config.brainRoot $config.allowedOwners -Refresh)
            foreach($old in $before){
                $new=@($after|Where-Object id -eq $old.id)
                if($new.Count -ne 1 -or $new[0].repository -cne $old.repository -or $new[0].path -cne $old.path -or $new[0].paraHash -cne $old.paraHash -or $new[0].trackerHash -cne $old.trackerHash -or $new[0].taskIds -cne $old.taskIds){throw (New-SBError 'paracli.customer.diverged' @($old.id))}
            }
            (Get-SBMessage 'paracli.customer.done' @($plan.Count))
        }
    }elseif($SetGitUpdate){
        # Git and GitHub update preference per repository: only the "gitUpdate" field of repository.json changes. Preview by default;
        # -Apply also needs -Confirmed. The value is a proposal for task closing, not an authorization: the runner and delegates never commit or push.
        $value=[ordered]@{mode=$GitMode}
        if($GitMode -ne 'none'){$value.branch=$(if($GitBranch){$GitBranch}else{'main'})}elseif($GitBranch){throw (New-SBError 'para.gitupdate.invalid')}
        if(!(Test-SBGitUpdate $value)){throw (New-SBError 'para.gitupdate.invalid')}
        $Only=@($Only|ForEach-Object {$_ -split ','}|ForEach-Object {$_.Trim()}|Where-Object {$_})
        $selected=@($index.entities|Where-Object {(Test-SBRepoDossier $_) -and ($_.id -in $Only -or $_.repository -in $Only)})
        if(!$selected.Count){throw (New-SBError 'paracli.customer.none')}
        if($Apply -and !$Confirmed){throw (New-SBError 'paracli.gitupdate.confirm')}
        $plan=@(foreach($item in ($selected|Sort-Object id)){
            $path=Join-Path (Resolve-SBParaPath $config.brainRoot $item.path) 'repository.json'
            $record=Read-SBJson $path $null
            $before=Get-SBGitUpdate $record
            $record.gitUpdate=$value
            $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))
            $previous=Get-SBFileHash $path
            [ordered]@{id=$item.id;repository=$item.repository;path=$item.path;before=$before;after=$value;changed=($previous -ne (Get-SBHash $bytes));file=$path;expected=$previous;bytes=$bytes}
        })
        $view=@($plan|ForEach-Object {[ordered]@{id=$_.id;repository=$_.repository;path=$_.path;before=$_.before;after=$_.after;changed=$_.changed}})
        if(!$Apply){
            ConvertTo-SBJson @{apply=$false;dossiers=$view}
            (Get-SBMessage 'paracli.gitupdate.plan' @($plan.Count))
        }else{
            $ops=@($plan|Where-Object changed|ForEach-Object {@{path=$_.file;expected=$_.expected;bytes=$_.bytes}})
            if($ops.Count){Invoke-SBParaTransaction $ops $BackupRoot $config.brainRoot}
            ConvertTo-SBJson @{apply=$true;dossiers=$view}
            (Get-SBMessage 'paracli.gitupdate.done' @($plan.Count))
        }
    }elseif($Archive -or $Restore){
        # No archive folders: archiving sets the terminal status of the entity (completed or retired), restoring sets it back to active. Nothing moves.
        $matches=@($index.entities|Where-Object id -eq $EntityId)
        if($matches.Count -ne 1){throw (New-SBError 'paracli.entity.unknown')};$item=$matches[0]
        if($Archive -and $item.archived){throw (New-SBError 'paracli.entity.archivedalready')}
        if($Restore -and !$item.archived){throw (New-SBError 'paracli.entity.activealready')}
        $newStatus=$(if($Restore){'active'}elseif($item.kind -eq 'project'){'completed'}else{'retired'})
        $metaPath=Join-Path (Resolve-SBParaPath $config.brainRoot $item.path) 'entity.json'
        $m=Read-SBJson $metaPath $null;$m.status=$newStatus
        Invoke-SBParaTransaction @(,@{path=$metaPath;expected=(Get-SBFileHash $metaPath);bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $m))}) $BackupRoot $config.brainRoot
    }
    if($writing){$index=Update-SBParaIndex $config}
    elseif(!$SuggestArchive){$index=Update-SBParaIndex $config -Check}
    if($SuggestArchive){$index.candidates|ConvertTo-Json -Depth 5}else{"PARA: $($index.entities.Count) entita; $($index.candidates.Count) proposte di archiviazione"}
} finally {Exit-SBOperation $lock}
