#requires -Version 7.5
# Fixtures for personal workspaces (#620, #621): registration without Git, private dossier, output scope, runner refusal. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Workspace.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:wsChecks=0
function Assert-Ws($Condition,[string]$Message){if(!$Condition){throw ('FAIL WORKSPACE: '+$Message)};$script:wsChecks++}
$root=Join-Path (Get-SBTestRoot) ('workspace-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain'
function Put([string]$rel,[string]$text){$p=Join-Path $brain $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text)}
try{
    foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
    Put 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
    $runtime=Get-SBLocalRoot $brain 'fixture';$cfg=Join-Path $runtime 'workstation.json'
    Put ([IO.Path]::GetRelativePath($brain,$cfg)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=$runtime;backupRoot=(Join-Path $runtime 'backups');ides=@();bindings=@()})
    $folder=Join-Path $root 'notes';[IO.Directory]::CreateDirectory((Join-Path $folder 'exports'))|Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'a.txt'),'synthetic')
    $cli=Join-Path $brain 'scripts/workspace.ps1'
    function Invoke-Ws([string[]]$Arguments){$out=& pwsh -NoProfile -File $cli -BrainRoot $brain -ConfigPath $cfg @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}
    $before=Get-SBFileHash (Join-Path $folder 'a.txt')

    # Preview writes nothing.
    $r=Invoke-Ws @('-Register','-Path',$folder,'-OutputScope','exports')
    Assert-Ws ($r.code -eq 0 -and $r.out -match '"apply":\s*false' -and $r.out -match 'local:[a-f0-9]{32}') ('preview prints the plan: '+$r.out)
    Assert-Ws (!(Test-Path -LiteralPath (Join-Path $brain 'workstation'))) 'preview creates no dossier'
    Assert-Ws (!(Read-SBJson $cfg @{}).ContainsKey('workspaces')) 'preview leaves workstation.json unchanged'

    # Apply registers a workspace, a private dossier, and never touches the folder or Git.
    $r=Invoke-Ws @('-Register','-Path',$folder,'-OutputScope','exports','-Apply')
    Assert-Ws ($r.code -eq 0) ('apply succeeds: '+$r.out)
    $station=Read-SBJson $cfg @{}
    $entries=@(Get-SBWorkspaceEntries $station)
    Assert-Ws ($entries.Count -eq 1 -and $entries[0].kind -eq 'workspace' -and $entries[0].identity -match '^local:[a-f0-9]{32}$') 'workspace entry registered with a local identity'
    Assert-Ws (@($station.bindings).Count -eq 0) 'repository bindings unchanged'
    Assert-Ws (!(Test-Path -LiteralPath (Join-Path $folder '.git'))) 'no .git created'
    Assert-Ws (@(Get-ChildItem -LiteralPath $folder -Recurse -Force).Count -eq 2 -and (Get-SBFileHash (Join-Path $folder 'a.txt')) -ceq $before) 'nothing written inside the workspace'
    $dossier=Join-Path $brain $entries[0].dossier
    Assert-Ws ((Test-Path -LiteralPath (Join-Path $dossier 'entity.json')) -and (Test-Path -LiteralPath (Join-Path $dossier 'brief.md')) -and (Test-Path -LiteralPath (Join-Path $dossier 'workspace.json'))) 'private dossier created'
    Assert-Ws (!(Test-Path -LiteralPath (Join-Path $dossier 'repository.json'))) 'dossier is not a repository dossier'
    Assert-Ws (@(Get-SBParaEntities $brain @('test')|Where-Object {$_.path -eq $entries[0].dossier}).Count -eq 1) 'dossier is a valid PARA entity'

    # Registration refusals.
    Assert-Ws ((Invoke-Ws @('-Register','-Path',$folder,'-Apply')).code -ne 0) 'duplicate registration refused'
    $git=Join-Path $root 'gitfolder';[IO.Directory]::CreateDirectory((Join-Path $git '.git'))|Out-Null
    Assert-Ws ((Invoke-Ws @('-Register','-Path',$git)).out -match 'Git checkout') 'a Git checkout is refused'
    Assert-Ws ((Invoke-Ws @('-Register','-Path',$brain)).code -ne 0) 'the brain folder is refused'
    $other=Join-Path $root 'other';[IO.Directory]::CreateDirectory($other)|Out-Null
    Assert-Ws ((Invoke-Ws @('-Register','-Path',$other,'-OutputScope','..\escape')).out -match 'relative subfolder') 'scope escaping the folder is refused'

    # Output scope (#621).
    $ok=Invoke-Ws @('-AssertWrite',(Join-Path $folder 'exports/out.md'))
    Assert-Ws ($ok.code -eq 0 -and $ok.out -match '"allowed":\s*true') 'write inside the output scope allowed'
    $no=Invoke-Ws @('-AssertWrite',(Join-Path $folder 'a.txt'))
    Assert-Ws ($no.code -eq 4 -and $no.out -match 'outside the permitted output scope') 'write outside the scope refused'
    $free=Invoke-Ws @('-AssertWrite',(Join-Path $root 'elsewhere.txt'))
    Assert-Ws ($free.code -eq 0 -and $free.out -match '"workspace":\s*false') 'paths outside any workspace are not governed here'

    # Read-only start: a workspace registered without scope permits no write.
    $ro=Join-Path $root 'readonly';[IO.Directory]::CreateDirectory($ro)|Out-Null
    $r=Invoke-Ws @('-Register','-Path',$ro,'-Apply')
    Assert-Ws ($r.code -eq 0) ('read-only workspace registered: '+$r.out)
    Assert-Ws ((Invoke-Ws @('-AssertWrite',(Join-Path $ro 'x.txt'))).code -eq 4) 'empty scope means read-only'

    # The runner refuses workspace targets.
    $runner=Join-Path $brain 'scripts/run-ready-tasks.ps1'
    $env:SECONDBRAIN_STATE_ROOT=$null
    $out=& pwsh -NoProfile -File $runner -CheckoutPath $folder -ConfigPath $cfg 2>&1|Out-String
    Assert-Ws ($LASTEXITCODE -eq 2 -and $out -match 'registered repositories only') ('runner refuses a workspace: '+$out)
    'SUCCESS WORKSPACE: '+$script:wsChecks+' checks'
}finally{
    $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath((Get-SBTestRoot)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Workspace fixture outside the test perimeter'}
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
