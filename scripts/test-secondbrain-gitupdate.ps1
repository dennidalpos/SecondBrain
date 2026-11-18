#requires -Version 7.5
# Fixtures for the per-repository Git and GitHub update preference (#656): validation, default, preview, confirmation, write. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:guChecks=0
function Assert-Gu($Condition,[string]$Message){if(!$Condition){throw ('FAIL GITUPDATE: '+$Message)};$script:guChecks++}
$root=Join-Path (Get-SBTestRoot) ('gitupdate-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain'
function Put([string]$rel,[string]$text){$p=Join-Path $brain $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text)}
try{
    # Pure validation and default.
    Assert-Gu (Test-SBGitUpdate @{mode='commit-push-main';branch='main'}) 'commit-push-main on main is valid'
    Assert-Gu (Test-SBGitUpdate @{mode='none'}) 'none is valid without a branch'
    Assert-Gu (!(Test-SBGitUpdate @{mode='force-push'})) 'unknown mode refused'
    Assert-Gu (!(Test-SBGitUpdate @{mode='branch-pr';branch='a..b'})) 'branch with .. refused'
    Assert-Gu (!(Test-SBGitUpdate @{mode='branch-pr';branch='x';extra=1})) 'unknown key refused'
    Assert-Gu (!(Test-SBGitUpdate 'commit-push-main')) 'non-object refused'
    $default=Get-SBGitUpdate @{identity='github.com/test/a'}
    Assert-Gu ($default.mode -ceq 'commit-push-main' -and $default.branch -ceq 'main' -and !$default.confirmed) 'default proposal is commit-push-main on main, not confirmed'
    $stored=Get-SBGitUpdate @{identity='x';gitUpdate=@{mode='branch-pr';branch='dev'}}
    Assert-Gu ($stored.mode -ceq 'branch-pr' -and $stored.branch -ceq 'dev' -and $stored.confirmed) 'stored preference is confirmed'

    # CLI on a fixture brain.
    foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
    Put 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
    foreach($name in @('a','b')){
        $d="repos/$name"
        Put "$d/repository.json" (ConvertTo-SBJson @{schemaVersion=1;identity="github.com/test/$name";tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
        Put "$d/entity.json" (ConvertTo-SBJson @{schemaVersion=1;id="dossier-$name";kind='project';title=$name;status='active'})
        Put "$d/brief.md" "# $name"; Put "$d/context.md" "# Context`n"; Put "$d/memory.md" "# Memory`n"
        Put "$d/tracker.json" (ConvertTo-SBJson @{schemaVersion=1;repository="github.com/test/$name";tasks=@(@{id="T-$name-1";title='one'});history=@()})
    }
    $runtime=Get-SBLocalRoot $brain 'fixture';$cfg=Join-Path $runtime 'workstation.json'
    Put ([IO.Path]::GetRelativePath($brain,$cfg)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=$runtime;backupRoot=(Join-Path $runtime 'backups');ides=@();bindings=@()})
    $para=Join-Path $brain 'scripts/entity.ps1'
    function Invoke-Para([string[]]$Arguments){$out=& pwsh -NoProfile -File $para -ConfigPath $cfg @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}
    Assert-Gu ((Invoke-Para @('-BuildIndex')).code -eq 0) 'fixture index built'
    $fileA=Join-Path $brain 'repos/a/repository.json';$fileB=Join-Path $brain 'repos/b/repository.json'
    $hashA=Get-SBFileHash $fileA;$hashB=Get-SBFileHash $fileB;$tracker=Get-SBFileHash (Join-Path $brain 'repos/a/tracker.json')
    $r=Invoke-Para @('-SetGitUpdate','-GitMode','commit-push-main','-GitBranch','main','-Only','github.com/test/a')
    Assert-Gu ($r.code -eq 0 -and $r.out -match '"apply":\s*false' -and (Get-SBFileHash $fileA) -ceq $hashA) ('preview writes nothing: '+$r.out)
    $r=Invoke-Para @('-SetGitUpdate','-GitMode','commit-push-main','-Only','github.com/test/a','-Apply')
    Assert-Gu ($r.code -ne 0 -and $r.out -match 'needs -Confirmed' -and (Get-SBFileHash $fileA) -ceq $hashA) 'apply without -Confirmed is refused and writes nothing'
    $r=Invoke-Para @('-SetGitUpdate','-GitMode','none','-GitBranch','main','-Only','github.com/test/a')
    Assert-Gu ($r.code -ne 0) 'none with a branch is refused'
    $r=Invoke-Para @('-SetGitUpdate','-GitMode','branch-pr','-GitBranch','feature/x','-Only','github.com/test/a','-Apply','-Confirmed')
    Assert-Gu ($r.code -eq 0) ('apply with -Confirmed succeeds: '+$r.out)
    $record=Read-SBJson $fileA $null
    Assert-Gu ($record.gitUpdate.mode -ceq 'branch-pr' -and $record.gitUpdate.branch -ceq 'feature/x' -and $record.identity -ceq 'github.com/test/a') 'gitUpdate written, identity unchanged'
    Assert-Gu ((Get-SBFileHash $fileB) -ceq $hashB -and (Get-SBFileHash (Join-Path $brain 'repos/a/tracker.json')) -ceq $tracker) 'other dossier and tracker untouched'
    Assert-Gu ((Get-SBGitUpdate $record).confirmed) 'written preference reads back as confirmed'
    # projects.ps1 -List (#657): read-only project list with task counts and the effective preference.
    $checkoutA=Join-Path $root 'checkout-a';[IO.Directory]::CreateDirectory($checkoutA)|Out-Null
    $station=Read-SBJson $cfg @{}
    $station.bindings=@(@{identity='github.com/test/a';path=$checkoutA;dossier='repos/a'},@{identity='github.com/test/b';path=(Join-Path $root 'missing-b');dossier='repos/b'})
    [IO.File]::WriteAllText($cfg,(ConvertTo-SBJson $station))
    $hashes=@($fileA,$fileB,$cfg)|ForEach-Object {Get-SBFileHash $_}
    $out=& pwsh -NoProfile -File (Join-Path $brain 'scripts/projects.ps1') -List -ConfigPath $cfg 2>&1|Out-String
    Assert-Gu ($LASTEXITCODE -eq 0) ('projects -List succeeds: '+$out)
    $list=($out|ConvertFrom-Json).projects
    Assert-Gu ($list.Count -eq 2 -and $list[0].identity -ceq 'github.com/test/a' -and $list[0].tasks.total -eq 1 -and $list[0].tasks.todo -eq 0) 'projects listed with tracker counts'
    Assert-Gu ($list[0].checkoutExists -and !$list[1].checkoutExists) 'missing checkout flagged'
    Assert-Gu ($list[0].gitUpdate.mode -ceq 'branch-pr' -and $list[0].gitUpdate.confirmed -and !$list[1].gitUpdate.confirmed) 'effective gitUpdate reported per project'
    Assert-Gu ((@($fileA,$fileB,$cfg)|ForEach-Object {Get-SBFileHash $_}) -join ',' -ceq ($hashes -join ',')) 'projects -List writes nothing'
    # Workspaces (#662): listed as kind workspace without a tracker, with output scope and access; status lists them too.
    $wsDir=Join-Path $root 'ws-one';[IO.Directory]::CreateDirectory((Join-Path $wsDir 'out'))|Out-Null
    $station=Read-SBJson $cfg @{}
    $station.workspaces=@(@{kind='workspace';identity='local:abc123';name='ws-one';path=$wsDir;dossier='workstation/workspace-ws-one-abc';outputScope=@('out')})
    [IO.File]::WriteAllText($cfg,(ConvertTo-SBJson $station))
    $out=& pwsh -NoProfile -File (Join-Path $brain 'scripts/projects.ps1') -List -ConfigPath $cfg 2>&1|Out-String
    Assert-Gu ($LASTEXITCODE -eq 0) ('projects -List with a workspace succeeds: '+$out)
    $list=@(($out|ConvertFrom-Json).projects)
    $ws=@($list|Where-Object {$_.kind -ceq 'workspace'})
    Assert-Gu ($list.Count -eq 3 -and $ws.Count -eq 1 -and $ws[0].identity -ceq 'local:abc123' -and $ws[0].tasks.total -eq 0 -and $ws[0].access -ceq 'scoped-write' -and $ws[0].outputScope -contains 'out' -and $ws[0].checkoutExists) 'workspace listed with scope and access, no tracker'
    Assert-Gu (@($list|Where-Object {$_.kind -ceq 'repository'}).Count -eq 2) 'repositories keep kind repository'
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1') -Force
    $hostCfg=Get-SBHostConfigPath $brain;[IO.Directory]::CreateDirectory((Split-Path $hostCfg))|Out-Null
    [IO.File]::WriteAllText($hostCfg,(ConvertTo-SBJson (Read-SBJson $cfg @{})))
    $status=Get-SBSetupStatus $brain
    Assert-Gu (@($status.workspaces).Count -eq 1 -and $status.workspaces[0].access -ceq 'scoped-write') 'setup status lists the workspace'
    'SUCCESS GITUPDATE: '+$script:guChecks+' checks'
}finally{
    $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath((Get-SBTestRoot)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Git update fixture outside the test perimeter'}
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
