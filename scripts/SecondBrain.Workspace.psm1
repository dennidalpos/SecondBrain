#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'workspace.path.missing' = @{ en = 'Workspace folder not found: {0}' }
    'workspace.path.git' = @{ en = 'The folder is a Git checkout: register it as a repository, not as a workspace ({0})' }
    'workspace.path.brain' = @{ en = 'The folder overlaps the SecondBrain checkout or the workstation state: {0}' }
    'workspace.path.bound' = @{ en = 'The folder overlaps a registered repository binding: {0}' }
    'workspace.path.duplicate' = @{ en = 'The folder is already registered as a workspace: {0}' }
    'workspace.name.invalid' = @{ en = 'Invalid workspace name: use letters, digits, dot, underscore or hyphen, up to 60 characters' }
    'workspace.scope.invalid' = @{ en = 'Output scope must be a relative subfolder of the workspace: {0}' }
    'workspace.write.denied' = @{ en = 'Write refused: {0} is outside the permitted output scope of the workspace' }
    'workspace.runner.refused' = @{ en = 'The task runner works on registered repositories only; {0} is a workspace' }
    'workspace.dossier.exists' = @{ en = 'The workspace dossier already exists: {0}' }
}

function Get-SBWorkspaceEntries($WorkstationConfig) {
    # Workspaces live beside, never inside, the repository bindings so that repository resolution stays unchanged.
    if($null -eq $WorkstationConfig -or !($WorkstationConfig -is [Collections.IDictionary]) -or !$WorkstationConfig.ContainsKey('workspaces')){return @()}
    @($WorkstationConfig.workspaces|Where-Object {$null -ne $_ -and $_.kind -eq 'workspace'})
}
function Test-SBPathInside([string]$Child,[string]$Parent) {
    $c=(ConvertTo-SBComparablePath $Child).TrimEnd('\','/');$p=(ConvertTo-SBComparablePath $Parent).TrimEnd('\','/')
    $c -ieq $p -or $c.StartsWith($p+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}
function Resolve-SBWorkspaceScope([string]$Root,[string[]]$OutputScope) {
    $scope=@()
    foreach($item in @($OutputScope|Where-Object {$_})){
        if([IO.Path]::IsPathRooted($item) -or $item -match '(^|[\\/])\.\.([\\/]|$)' -or $item -match '[\p{Cc}]'){throw (New-SBError 'workspace.scope.invalid' @($item))}
        $full=[IO.Path]::GetFullPath((Join-Path $Root $item))
        if(!(Test-SBPathInside $full $Root)){throw (New-SBError 'workspace.scope.invalid' @($item))}
        $scope+=[IO.Path]::GetRelativePath($Root,$full).Replace('\','/')
    }
    @($scope|Sort-Object -Unique)
}
function New-SBWorkspacePlan([string]$BrainRoot,$WorkstationConfig,[string]$Path,[string]$Name='',[string[]]$OutputScope=@(),[string[]]$StateRoots=@()) {
    if(!(Test-Path -LiteralPath $Path -PathType Container)){throw (New-SBError 'workspace.path.missing' @($Path))}
    $root=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if(!$Name){$Name=[IO.Path]::GetFileName($root)}
    if($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$'){throw (New-SBError 'workspace.name.invalid')}
    # Registration never initializes or reads Git state beyond detecting a checkout.
    if(Test-Path -LiteralPath (Join-Path $root '.git')){throw (New-SBError 'workspace.path.git' @($root))}
    foreach($state in @($BrainRoot)+@($StateRoots|Where-Object {$_})){
        if((Test-SBPathInside $root $state) -or (Test-SBPathInside $state $root)){throw (New-SBError 'workspace.path.brain' @($root))}
    }
    $bindings=@(); if($WorkstationConfig -is [Collections.IDictionary] -and $WorkstationConfig.ContainsKey('bindings')){$bindings=@($WorkstationConfig.bindings)}
    foreach($binding in $bindings){if($binding.path -and ((Test-SBPathInside $root $binding.path) -or (Test-SBPathInside $binding.path $root))){throw (New-SBError 'workspace.path.bound' @($root))}}
    foreach($entry in @(Get-SBWorkspaceEntries $WorkstationConfig)){if(Test-SBSamePath $entry.path $root){throw (New-SBError 'workspace.path.duplicate' @($root))}}
    $scope=@(Resolve-SBWorkspaceScope $root $OutputScope)
    $hostId=Get-SBHostId
    $hash=Get-SBTextHash ('workspace|'+$hostId+'|'+$root.ToLowerInvariant())
    $identity='local:'+$hash.Substring(0,32).ToLowerInvariant()
    $dossier='02-areas/workspace-'+($Name.ToLowerInvariant() -replace '[^a-z0-9-]','-')+'-'+$hash.Substring(0,8).ToLowerInvariant()
    [ordered]@{kind='workspace';identity=$identity;name=$Name;path=$root;dossier=$dossier;outputScope=@($scope);access=$(if($scope.Count){'scoped-write'}else{'read-only'})}
}
function Get-SBWorkspaceSeed($Plan) {
    $id='workspace-'+($Plan.identity -replace '^local:','').Substring(0,20)
    $access=if($Plan.outputScope.Count){'Writes are allowed only in: '+($Plan.outputScope -join ', ')+'.'}else{'Sessions start read-only: no output folder is permitted.'}
    @{
        'para.json'=(ConvertTo-SBJson @{schemaVersion=1;id=$id;kind='area';title=('Workspace '+$Plan.name);status='active'})
        'workspace.json'=(ConvertTo-SBJson @{schemaVersion=1;kind='workspace';identity=$Plan.identity;name=$Plan.name;outputScope=@($Plan.outputScope);access=$Plan.access})
        'brief.md'=("# Workspace "+$Plan.name+"`n`nPersonal workspace without Git. "+$access+"`nSecondBrain state stays outside the workspace folder.`n")
    }
}
function Register-SBWorkspace($Config,[string]$WorkstationConfigPath,$Plan,[string]$BackupRoot) {
    $dossierPath=Join-Path $Config.brainRoot $Plan.dossier
    $seed=Get-SBWorkspaceSeed $Plan
    foreach($name in $seed.Keys){if(Test-Path -LiteralPath (Join-Path $dossierPath $name)){throw (New-SBError 'workspace.dossier.exists' @($Plan.dossier))}}
    $workstation=Read-SBJson $WorkstationConfigPath @{}
    $entries=@(Get-SBWorkspaceEntries $workstation)
    $entry=@{kind='workspace';identity=$Plan.identity;name=$Plan.name;path=$Plan.path;dossier=$Plan.dossier;outputScope=@($Plan.outputScope);registeredAt=(Get-SBNow).ToString('o')}
    $expected=Get-SBFileHash $WorkstationConfigPath
    foreach($name in ($seed.Keys|Sort-Object)){Write-SBFile (Join-Path $dossierPath $name) ([Text.Encoding]::UTF8.GetBytes($seed[$name])) 'absent' $BackupRoot|Out-Null}
    $workstation.workspaces=@($entries+@($entry))
    Write-SBFile $WorkstationConfigPath ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $workstation))) $expected $BackupRoot|Out-Null
    $entry
}
function Find-SBWorkspaceFor($WorkstationConfig,[string]$Path) {
    if(!$Path){return $null}
    foreach($entry in @(Get-SBWorkspaceEntries $WorkstationConfig)){if(Test-SBPathInside $Path $entry.path){return $entry}}
    $null
}
function Assert-SBWorkspaceWrite($Entry,[string]$Target) {
    # Writes are refused unless the target sits inside a permitted output subfolder; an empty scope means read-only.
    $full=[IO.Path]::GetFullPath($Target)
    foreach($relative in @($Entry.outputScope)){
        if(Test-SBPathInside $full (Join-Path $Entry.path $relative)){return $true}
    }
    throw (New-SBError 'workspace.write.denied' @($full))
}
function Assert-SBNotWorkspace($WorkstationConfig,[string]$Path) {
    # The software-task runner stays tied to registered repositories.
    $entry=Find-SBWorkspaceFor $WorkstationConfig $Path
    if($entry){throw (New-SBError 'workspace.runner.refused' @($entry.name))}
}
Export-ModuleMember -Function Get-SBWorkspaceEntries,New-SBWorkspacePlan,Register-SBWorkspace,Find-SBWorkspaceFor,Assert-SBWorkspaceWrite,Assert-SBNotWorkspace
