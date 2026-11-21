#requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.SetupStatus.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$passed=0
function Assert-Setup($Value,[string]$Message){if(!$Value){throw "FAIL SETUP-STATUS: $Message"};$script:passed++;"PASS SETUP-STATUS: $Message"}
function Set-Fixture([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
$root=Join-Path (Get-SBTestRoot) ('secondbrain-setup-status-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$repo=Join-Path $root 'repo'
[IO.Directory]::CreateDirectory((Join-Path $repo '.git/hooks'))|Out-Null
$settings=Join-Path $root 'claude-settings.json'
Set-Fixture $settings '{}'
Set-Fixture (Join-Path $root '.runtime/trace/ws/2026-01-01.jsonl') ('{"secret":"must not be read"}'+"`n"+'{"secret":"x"}'+"`n")
Set-Fixture (Join-Path $root 'shared/authoritative-sources/entries/x/metadata.json') '{}'
$ides=@(@{name='Claude Code';adapter='claude-code';mcpConfigured=$false},@{name='VS Code';adapter='vscode';mcpConfigured=$true},@{name='Android Studio';adapter='android-studio';mcpConfigured=$false},@{name='Claude account instructions';adapter='manual';mcpConfigured=$false})
$bindings=@(@{path=$repo;identity='github.com/example/repo'})
$before=@(Get-ChildItem -LiteralPath $root -Recurse -File|ForEach-Object {$_.FullName+'|'+(Get-SBFileHash $_.FullName)})
$features=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue '' -SettingsPath $settings -Ides $ides -Bindings $bindings -Config @{})
$byId={param($id,$scope) @($features|Where-Object {$_.id -eq $id -and (!$scope -or $_.scope -eq $scope)})[0]}
Assert-Setup ((& $byId 'environment').state -eq 'available' -and (& $byId 'environment').recommended) 'SECONDBRAIN_HOME assente: funzione proposta'
Assert-Setup ((& $byId 'mcp' 'Claude Code').recommended -and (& $byId 'mcp' 'Claude Code').state -eq 'available') 'IDE senza MCP: abilitazione consigliata'
Assert-Setup ((& $byId 'mcp' 'VS Code').state -eq 'enabled' -and !(& $byId 'mcp' 'VS Code').recommended) 'IDE con MCP: gia abilitato, non consigliato'
Assert-Setup ((& $byId 'mcp' 'Android Studio').state -eq 'unsupported') 'IDE senza target MCP: non supportato'
Assert-Setup ((& $byId 'trace-hook').state -eq 'available') 'hook Trace proposto per Claude Code'
Assert-Setup ((& $byId 'resources-hook').recommended) 'hook risorse consigliato con registro fonti presente'
Assert-Setup ((& $byId 'publication-hook').state -eq 'unsupported') 'repository senza remote: hook di pubblicazione non proposto'
Assert-Setup ((& $byId 'task-launcher').state -eq 'available' -and !(& $byId 'task-launcher').recommended) 'lanciatore proposto ma non consigliato di default'
Assert-Setup (!(& $byId 'activity-register').recommended -and (& $byId 'activity-register').risk -eq 'high') 'registro attivita mai consigliato (rischio alto)'
Assert-Setup (@($features|Where-Object {$_.state -eq 'available' -and !$_.enableCommand}).Count -eq 0) 'ogni funzione disponibile ha un comando di anteprima'
$account=& $byId 'manual-directives'
Assert-Setup ($account.state -eq 'blocked' -and $account.recommended -and $account.enableCommand) 'istruzioni account senza osservazione: segnalate e consigliate'
$enabled=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue 'C:\x' -SettingsPath $settings -Ides @() -Bindings @() -Config @{activityLogEnabled=$true})
Assert-Setup ((@($enabled|Where-Object id -eq 'environment')[0]).state -eq 'enabled' -and (@($enabled|Where-Object id -eq 'activity-register')[0]).state -eq 'enabled') 'stato abilitato riconosciuto'
$usage=Get-SBTraceUsage $root
Assert-Setup ($usage.present -and $usage.events -eq 2 -and (ConvertTo-SBJson $usage) -notmatch 'secret') 'uso dal Trace: solo conteggi, nessun contenuto'
$after=@(Get-ChildItem -LiteralPath $root -Recurse -File|ForEach-Object {$_.FullName+'|'+(Get-SBFileHash $_.FullName)})
Assert-Setup (($before -join "`n") -ceq ($after -join "`n")) 'nessun file creato o modificato'
$state=Join-Path $root 'state'
$approved='Revisione 1.0 - testo approvato di prova'
Set-Fixture (Join-Path $state 'istruzioni-globali.md') $approved
$approvedHash=Get-SBTextHash $approved.Trim()
$accountIde=@(@{name='Claude account instructions';adapter='manual';mcpConfigured=$false})
$writeMap={param($hash) Set-Fixture (Join-Path $state 'ide-map.json') (ConvertTo-SBJson @{schemaVersion=1;ides=@(@{name='Claude account instructions';mode='manual';selected=$true;observedHash=$hash})})}
& $writeMap $approvedHash
$ok=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue 'x' -SettingsPath $settings -Ides $accountIde -Bindings @() -Config @{} -StateRoot $state|Where-Object id -eq 'manual-directives')[0]
Assert-Setup ($ok.state -eq 'enabled' -and !$ok.recommended) 'istruzioni account con hash osservato uguale: enabled, non consigliato'
& $writeMap ('0'*64)
$stale=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue 'x' -SettingsPath $settings -Ides $accountIde -Bindings @() -Config @{} -StateRoot $state|Where-Object id -eq 'manual-directives')[0]
Assert-Setup ($stale.state -eq 'blocked' -and $stale.recommended) 'istruzioni account con hash obsoleto: blocked e consigliato'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.ClientHooks.psm1') -Force
$backups=Join-Path $root 'backups'
$alt=@(@{name='Codex';adapter='codex';mcpConfigured=$true},@{name='Antigravity';adapter='antigravity';mcpConfigured=$true})
foreach($client in 'claude-code','codex','antigravity'){
    $path=Join-Path $root ('hooks-'+$client+'.json')
    Set-Fixture $path ('{"model":"x","hooks":{"Notification":[{"hooks":[{"type":"command","command":"other"}]}]}}')
    $original=Get-SBFileHash $path
    $preview=Set-SBClientHooks $root $backups $client $path
    Assert-Setup ($preview.preview -and !$preview.applied -and $preview.changed -and $preview.hooks.Count -eq 2 -and !$preview.grantsWritePermission -and (Get-SBFileHash $path) -eq $original) "$client`: anteprima senza -Apply non modifica il file"
    $applied=Set-SBClientHooks $root $backups $client $path -Apply
    $status=Get-SBClientHookStatus $root $client $path
    Assert-Setup ($applied.applied -and @($status.hooks|Where-Object installed).Count -eq 2) "$client`: -Apply installa resources-hook e trace-hook"
    Assert-Setup (@(Get-ChildItem -LiteralPath $backups -Recurse -File).Count -ge 1) "$client`: backup creato"
    $text=Get-Content -LiteralPath $path -Raw
    Assert-Setup ($text -match '"command": ?"other"' -and $text -match '"model"') "$client`: voci altrui conservate"
    $again=Set-SBClientHooks $root $backups $client $path -Apply
    Assert-Setup (!$again.changed -and !$again.applied) "$client`: idempotente"
    $removed=Set-SBClientHooks $root $backups $client $path -Remove -Apply
    $after=Get-SBClientHookStatus $root $client $path
    $kept=Get-Content -LiteralPath $path -Raw
    Assert-Setup ($removed.applied -and @($after.hooks|Where-Object installed).Count -eq 0 -and $kept -match '"other"' -and $kept -notmatch 'resources-hook|trace\.ps1') "$client`: rimozione toglie solo le voci SecondBrain"
}
$bad=Join-Path $root 'bad.json';Set-Fixture $bad '{not json'
$badError=$null;try{[void](Set-SBClientHooks $root $backups 'codex' $bad -Apply)}catch{$badError=$_}
Assert-Setup ($null -ne $badError -and (Get-Content -LiteralPath $bad -Raw) -eq '{not json') 'JSON non valido: errore, nessuna sovrascrittura'
$cfg=@{codex=(Join-Path $root 'status-codex.json');antigravity=(Join-Path $root 'status-ag.json')}
$statusFeatures=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue 'x' -SettingsPath $settings -Ides $alt -Bindings @() -Config @{} -ClientSettingsPaths $cfg)
foreach($client in 'codex','antigravity'){
    foreach($name in 'trace-hook','resources-hook'){
        $f=@($statusFeatures|Where-Object {$_.id -eq $name -and $_.scope -eq $client})
        Assert-Setup ($f.Count -eq 1 -and $f[0].state -eq 'available' -and $f[0].enableCommand -match 'client-hooks\.ps1') "$client`: setup-status riporta $name disponibile"
    }
}
[void](Set-SBClientHooks $root $backups 'codex' $cfg.codex -Apply)
$statusAfter=@(Get-SBSetupFeatureStatus -BrainRoot $root -HomeValue 'x' -SettingsPath $settings -Ides $alt -Bindings @() -Config @{} -ClientSettingsPaths $cfg)
$hookFeatures=@($statusAfter|Where-Object {$_.id -match '-hook$'})
Assert-Setup (@($hookFeatures|Where-Object {$_.scope -eq 'codex' -and $_.state -eq 'enabled'}).Count -eq 2 -and @($hookFeatures|Where-Object {$_.scope -eq 'antigravity' -and $_.state -eq 'available'}).Count -eq 2) 'setup-status riporta lo stato per client'
# Written, loaded and verified are three separate states; only receipts raise loaded and verified.
$withStates=@(Add-SBFeatureStates $statusAfter @())
$codexOn=@($withStates|Where-Object {$_.id -eq 'trace-hook' -and $_.scope -eq 'codex'})[0]
Assert-Setup ($codexOn.states.written -and $codexOn.states.loaded -eq 'unverified' -and $codexOn.states.verified -eq 'unverified') 'written without receipts: loaded and verified stay unverified'
$agOff=@($withStates|Where-Object {$_.id -eq 'trace-hook' -and $_.scope -eq 'antigravity'})[0]
Assert-Setup (!$agOff.states.written -and $agOff.states.loaded -eq 'not-applicable' -and $agOff.states.verified -eq 'not-applicable') 'not written: loaded and verified not applicable'
$loadedOnly=@(Add-SBFeatureStates $statusAfter @(@{id='trace-hook';scope='codex';loaded=$true;verified=$false}))
$loadedEntry=@($loadedOnly|Where-Object {$_.id -eq 'trace-hook' -and $_.scope -eq 'codex'})[0]
Assert-Setup ($loadedEntry.states.loaded -eq 'confirmed' -and $loadedEntry.states.verified -eq 'unverified') 'loaded receipt does not imply live verification'
$verifiedEntry=@(Add-SBFeatureStates $statusAfter @(@{id='trace-hook';scope='codex';loaded=$true;verified=$true})|Where-Object {$_.id -eq 'trace-hook' -and $_.scope -eq 'codex'})[0]
Assert-Setup ($verifiedEntry.states.loaded -eq 'confirmed' -and $verifiedEntry.states.verified -eq 'confirmed') 'verified receipt recorded separately'
$stateRoot=Join-Path $root 'state';[IO.Directory]::CreateDirectory($stateRoot)|Out-Null
Set-Fixture (Join-Path $stateRoot 'setup-verification.json') '{"entries":[{"id":"mcp","scope":"x","loaded":true,"verified":false}]}'
Assert-Setup (@(Get-SBSetupVerification $stateRoot).Count -eq 1 -and @(Get-SBSetupVerification (Join-Path $root 'none')).Count -eq 0) 'verification receipts read; missing file means none'
# Interrupted setup: progress is kept per discovery report and resumes at the first incomplete step.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1') -Force
$paths=@{progress=(Join-Path $stateRoot 'setup-progress.json');backupRoot=(Join-Path $stateRoot 'backups')}
$sha='A'*64
Assert-Setup ((Get-SBSetupResumePoint $null $sha).from -eq 'discovery' -and !(Get-SBSetupResumePoint $null $sha).resumed) 'no progress: fresh run from the first step'
Set-SBSetupProgress $paths $sha 'discovery';Set-SBSetupProgress $paths $sha 'selection';Set-SBSetupProgress $paths $sha 'activation'
$interrupted=Get-SBSetupResumePoint (Get-SBSetupProgress $paths) $sha
Assert-Setup ($interrupted.resumed -and $interrupted.from -eq 'mcp' -and (@($interrupted.completed) -join ',') -eq 'discovery,selection,activation') 'interrupted after activation: resumes at mcp'
Set-SBSetupProgress $paths $sha 'activation'
Assert-Setup (@((Get-SBSetupProgress $paths).steps).Count -eq 3) 'repeating a step does not duplicate it'
$other=Get-SBSetupResumePoint (Get-SBSetupProgress $paths) ('B'*64)
Assert-Setup (!$other.resumed -and $other.from -eq 'discovery') 'different discovery report: no resume, fresh run'
Set-SBSetupProgress $paths $sha 'mcp';Set-SBSetupProgress $paths $sha 'sync';Set-SBSetupProgress $paths $sha 'report' -Complete
$finished=Get-SBSetupResumePoint (Get-SBSetupProgress $paths) $sha
Assert-Setup (!$finished.resumed -and (Get-SBSetupProgress $paths).status -eq 'complete') 'complete run is not resumed'
# sb install: one command chains preflight, Setup and enrolment; preview changes nothing, -Apply leaves the workstation active.
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cloneRoot=Join-Path $root 'install-clone';$installProject=Join-Path $root 'install-project'
$savedEnv=@{}
foreach($name in @('SECONDBRAIN_TEST_ROOT','SECONDBRAIN_TEST_RUN_CONTEXT','SECONDBRAIN_TEST_KEEP','SECONDBRAIN_HOME','SECONDBRAIN_STATE_ROOT')){$savedEnv[$name]=[Environment]::GetEnvironmentVariable($name,'Process');[Environment]::SetEnvironmentVariable($name,$null,'Process')}
try{
    & git -c core.longpaths=true clone -q --no-hardlinks $sourceRoot $cloneRoot 2>&1|Out-Null
    foreach($relative in (@(& git -c core.quotepath=false -C $sourceRoot ls-files -z --cached --others --exclude-standard|ForEach-Object {$_}) -join '') -split "`0"|Where-Object {$_}){
        $from=Join-Path $sourceRoot $relative
        if(!(Test-Path -LiteralPath $from -PathType Leaf)){continue}
        $to=Join-Path $cloneRoot $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $to))
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
    [void][IO.Directory]::CreateDirectory($installProject)
    & git -C $installProject init -q
    & git -C $installProject remote add origin 'https://github.com/test/install-fixture.git'
    Set-Fixture (Join-Path $installProject 'README.md') "# Synthetic project`n"
    $installScript=Join-Path $cloneRoot 'scripts/install.ps1'
    $runInstall={param([string[]]$Extra) $out=@(& pwsh -NoProfile -File $installScript -Roots $installProject -NoRegisterEnvironment @Extra 2>&1);@{code=$LASTEXITCODE;data=((@($out|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]}) -join "`n")|ConvertFrom-Json -AsHashtable)}}
    $previewRun=& $runInstall @()
    Assert-Setup ($previewRun.code -eq 0 -and $previewRun.data.stage -eq 'preview' -and $previewRun.data.checks.git -and !(Test-Path -LiteralPath (Join-Path $cloneRoot '.runtime/hosts')) -and @(Get-ChildItem -LiteralPath $installProject -Force|Where-Object Name -notin '.git','README.md').Count -eq 0) 'install preview: preflight passes, nothing written'
    $applyRun=& $runInstall @('-Apply')
    $installStatus=@(& pwsh -NoProfile -File (Join-Path $cloneRoot 'scripts/secondbrain.ps1') -Setup -Status 2>&1|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]})-join "`n"|ConvertFrom-Json -AsHashtable
    Assert-Setup ($applyRun.code -eq 0 -and $applyRun.data.stage -eq 'applied' -and (Test-Path -LiteralPath (Join-Path $cloneRoot '.runtime/hosts')) -and (Test-Path -LiteralPath (Join-Path $installProject 'AGENTS.md')) -and $installStatus.stage -eq 'status') 'install -Apply: workstation active and repository enrolled'
}finally{
    foreach($name in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnv[$name],'Process')}
}
'SUCCESS SETUP-STATUS: '+$passed+' verifiche'
