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
Set-Fixture (Join-Path $root '03-resources/authoritative-sources/entries/x/metadata.json') '{}'
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
'SUCCESS SETUP-STATUS: '+$passed+' verifiche'
