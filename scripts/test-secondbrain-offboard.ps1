#requires -Version 7.5
# sb offboard (#725): preview changes nothing; apply leaves the checkout as a fresh clone plus TASKS.md. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Knowledge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Entity.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:offChecks=0
function Assert-Off($Condition,[string]$Message){if(!$Condition){throw ('FAIL OFFBOARD: '+$Message)};$script:offChecks++}
$root=Join-Path (Get-SBTestRoot) ('offboard-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain'
$checkout=Join-Path $root 'checkout'
function Put([string]$base,[string]$rel,[string]$text){$p=Join-Path $base $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text)}
foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
Put $brain 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
$identity='github.com/test/offboard'
Put $brain 'repos/off/repository.json' (ConvertTo-SBJson @{schemaVersion=1;identity=$identity;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
Put $brain 'repos/off/entity.json' (ConvertTo-SBJson @{schemaVersion=1;id='dossier-off';kind='project';title='off';status='active'})
Put $brain 'repos/off/brief.md' '# off'
Put $brain 'repos/off/context.md' '# Context'
Put $brain 'repos/off/memory.md' '# Memory'
Put $brain 'repos/off/tracker.json' (ConvertTo-SBJson @{schemaVersion=1;repository=$identity;history=@();tasks=@(
    @{id='T-1';seq=1;title='Finished work';status='done';priority='P2'},
    @{id='T-2';seq=2;title='Open work';status='todo';priority='P1'},
    @{id='T-3';seq=3;title='Blocked work';status='blocked';priority='P3'})})
$agents="# Product`n`nOwn text.`n`n<!-- secondbrain:repository:begin -->`nmanaged block`n<!-- secondbrain:repository:end -->`n"
Put $checkout 'AGENTS.md' $agents
Put $checkout 'src/code.txt' 'product code'
$null=& git -C $checkout init -q 2>&1
$cfgPath=Get-SBHostConfigPath $brain
Put $brain ([IO.Path]::GetRelativePath($brain,$cfgPath)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=(Join-Path $brain '.runtime/hosts/fixture');backupRoot=(Join-Path $brain '.runtime/hosts/fixture/backups');localStateBackupRoot=(Join-Path $brain '.runtime/hosts/fixture/state-backups');allowedOwners=@('test');ides=@();bindings=@(@{identity=$identity;path=$checkout;status='managed'})})
$offboard=Join-Path $brain 'scripts/offboard.ps1'
function Invoke-Off([string[]]$Arguments){$out=& pwsh -NoProfile -File $offboard -RepositoryIdentity $identity -ConfigPath $cfgPath @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}

$agentsBefore=Get-SBFileHash (Join-Path $checkout 'AGENTS.md')
$preview=Invoke-Off @()
Assert-Off ($preview.code -eq 0 -and (Test-Path -LiteralPath (Join-Path $brain 'repos/off')) -and !(Test-Path -LiteralPath (Join-Path $checkout 'TASKS.md')) -and (Get-SBFileHash (Join-Path $checkout 'AGENTS.md')) -ceq $agentsBefore) ('preview changes nothing: '+$preview.out)
$apply=Invoke-Off @('-Apply')
Assert-Off ($apply.code -eq 0) ('apply succeeds: '+$apply.out)
$tasks=[IO.File]::ReadAllText((Join-Path $checkout 'TASKS.md'))
Assert-Off ($tasks -match 'Open work' -and $tasks -match 'Blocked work' -and $tasks -notmatch 'Finished work') 'TASKS.md lists only the open tasks'
$after=[IO.File]::ReadAllText((Join-Path $checkout 'AGENTS.md'))
Assert-Off ($after -notmatch 'secondbrain:repository' -and $after -match 'Own text') 'the managed block is removed and user text is kept'
Assert-Off (!(Test-Path -LiteralPath (Join-Path $checkout '.secondbrain')) -and (Test-Path -LiteralPath (Join-Path $checkout 'src/code.txt'))) 'no dossier copy in the checkout, product files untouched'
Assert-Off (!(Test-Path -LiteralPath (Join-Path $brain 'repos/off'))) 'the dossier is removed from the brain'
Assert-Off (@(Get-ChildItem -LiteralPath (Join-Path $brain '.runtime/hosts/fixture/backups') -Directory -Filter 'rollback-*' -ErrorAction SilentlyContinue).Count -eq 1) 'the dossier is saved in the backup folder first'
$cfgAfter=Read-SBJson $cfgPath @{}
Assert-Off (@($cfgAfter.bindings|Where-Object identity -ceq $identity).Count -eq 0) 'the binding is removed'
'SUCCESS OFFBOARD: '+$script:offChecks+' checks; retained fixture '+$root
