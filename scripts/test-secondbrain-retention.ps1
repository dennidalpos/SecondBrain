#requires -Version 7.5
# Runtime retention rule (#732): fixed names only, older than the window, preview by default, -Apply needs authorization. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:retChecks=0
function Assert-Ret($Condition,[string]$Message){if(!$Condition){throw ('FAIL RETENTION: '+$Message)};$script:retChecks++}
$root=Join-Path (Get-SBTestRoot) ('retention-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain';$runtime=Join-Path $brain '.runtime'
function Put([string]$rel,[string]$text,[int]$AgeDays){$p=Join-Path $runtime $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text);$old=(Get-Date).AddDays(-$AgeDays);(Get-Item -LiteralPath $p).LastWriteTime=$old;(Get-Item -LiteralPath (Split-Path $p)).LastWriteTime=$old}
Put 'pub546.out' 'old output' 30
Put 't546-full.out' 'old output' 30
Put 't900-new.out' 'recent output' 1
Put 'smoke-5322d350/log.txt' 'old smoke' 30
Put 'smoke-aaaaaaaa/log.txt' 'recent smoke' 2
Put 'notes.out' 'not a leftover name' 60
Put 'access/session.json' 'protected' 90
Put 'hosts/h/state.json' 'protected' 90
$plan=Get-SBRuntimeLeftovers $runtime 14
$names=@($plan.targets|ForEach-Object name|Sort-Object)
Assert-Ret (($names -join ',') -ceq 'pub546.out,smoke-5322d350,t546-full.out') ('only old leftovers with a fixed name are selected: '+($names -join ','))
Assert-Ret (@($plan.skipped|Where-Object reason -eq 'within-retention-window').Count -eq 2) 'recent leftovers are skipped with a reason'
Assert-Ret (!(@($plan.targets|Where-Object {$_.name -in @('notes.out','access','hosts')}).Count)) 'other names and protected folders are never selected'
Assert-Ret ((Get-SBRuntimeLeftovers $runtime 60).targets.Count -eq 0) 'a longer window selects nothing'
# CLI: preview changes nothing; apply needs authorization.
foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
$cfgPath=Get-SBHostConfigPath $brain
[IO.Directory]::CreateDirectory((Split-Path $cfgPath))|Out-Null
[IO.File]::WriteAllText($cfgPath,(ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=(Join-Path $runtime 'hosts/fixture');backupRoot=(Join-Path $runtime 'hosts/fixture/backups');localStateBackupRoot=(Join-Path $runtime 'hosts/fixture/state-backups');ides=@();bindings=@()}))
$cleanup=Join-Path $brain 'scripts/cleanup.ps1'
function Invoke-Clean([string[]]$Arguments){$out=& pwsh -NoProfile -File $cleanup -ConfigPath $cfgPath @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}
$preview=Invoke-Clean @('-Leftovers')
Assert-Ret ($preview.code -eq 0 -and (Test-Path -LiteralPath (Join-Path $runtime 'pub546.out')) -and $preview.out -match 'Preview') ('preview removes nothing: '+$preview.out)
$noAuth=Invoke-Clean @('-Leftovers','-Apply')
Assert-Ret ($noAuth.code -ne 0 -and (Test-Path -LiteralPath (Join-Path $runtime 'pub546.out'))) 'apply without authorization is refused and removes nothing'
$apply=Invoke-Clean @('-Leftovers','-Apply','-Authorization','owner asked to apply the retention rule')
Assert-Ret ($apply.code -eq 0 -and !(Test-Path -LiteralPath (Join-Path $runtime 'pub546.out')) -and !(Test-Path -LiteralPath (Join-Path $runtime 'smoke-5322d350')) -and !(Test-Path -LiteralPath (Join-Path $runtime 't546-full.out'))) ('apply removes the listed leftovers: '+$apply.out)
Assert-Ret ((Test-Path -LiteralPath (Join-Path $runtime 't900-new.out')) -and (Test-Path -LiteralPath (Join-Path $runtime 'smoke-aaaaaaaa')) -and (Test-Path -LiteralPath (Join-Path $runtime 'notes.out')) -and (Test-Path -LiteralPath (Join-Path $runtime 'access/session.json'))) 'recent, unrelated and protected entries stay'
Assert-Ret (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'cleanup') -Filter 'leftovers-*.json').Count -eq 1) 'a journal is written'
'SUCCESS RETENTION: '+$script:retChecks+' checks; retained fixture '+$root
