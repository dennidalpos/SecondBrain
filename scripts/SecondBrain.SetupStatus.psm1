#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Trace.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.ClientHooks.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'setupstatus.exit.inactive'     = @{ en = 'Exit 1: the workstation is not activated; run sb setup to activate it' }
    'setupstatus.exit.recommended'  = @{ en = 'Exit 1: {0} recommended features are not enabled yet (see recommended and the entries with recommended=true); this is not an error' }
    'setupstatus.exit.ok'           = @{ en = 'Exit 0: activated and nothing to recommend' }
    'setupstatus.env.reason'        = @{ en = 'The task launcher and the publication hook require SECONDBRAIN_HOME.' }
    'setupstatus.mcp.reason'        = @{ en = 'IDE detected without the SecondBrain MCP server: the agent cannot reach dossiers and prompts.' }
    'setupstatus.trace.reason'      = @{ en = 'Claude Code detected: the Stop hook signals compaction; it grants no write permission.' }
    'setupstatus.clienttrace.reason' = @{ en = 'Client detected: the end-of-turn hook signals compaction; it grants no write permission.' }
    'setupstatus.resources.reason' = @{ en = 'Refreshes the authoritative sources at session start when the last check is older than 14 days.' }
    'setupstatus.publication.reason' = @{ en = 'The repository has a remote: the pre-push hook runs the publication scan before every push.' }
    'setupstatus.launcher.reason'   = @{ en = 'Lets the runner execute ready tasks; requires SECONDBRAIN_HOME.' }
    'setupstatus.activity.reason'   = @{ en = 'Optional team activity register: requires a declared privacy notice and retention.' }
    'setupstatus.account.reason'    = @{ en = 'Account instructions are not a file: paste them by hand (text in istruzioni-globali.md) and prove them with an observation receipt; otherwise the global directives do not apply in chats.' }
    'setupstatus.gitupdate.reason'  = @{ en = 'Choose how SecondBrain proposes Git and GitHub updates at task closing (default: commit and push on the main branch). It is a preference: nothing is committed or pushed without your explicit confirmation, and the runner never commits.' }
    'setupstatus.blocked.inactive'  = @{ en = 'Workstation not activated: run workstation.activate first.' }
}
function New-SBFeature([string]$Id,[string]$State,[string]$Evidence,[string]$Command,[string[]]$Prerequisites=@(),[string]$Risk='low',[bool]$Recommended=$false,[string]$ReasonKey,[string]$Scope='') {
    [ordered]@{id=$Id;scope=$Scope;state=$State;evidence=$Evidence;enableCommand=$Command;prerequisites=@($Prerequisites);risk=$Risk;recommended=$Recommended;reason=$(if($ReasonKey){Get-SBMessage $ReasonKey}else{''})}
}
function Get-SBTraceUsage([string]$BrainRoot) {
    # Counts only: files and events per day. Never reads event contents.
    $root=Join-Path ([IO.Path]::GetFullPath($BrainRoot)) '.runtime/trace'
    $files=@(if(Test-Path -LiteralPath $root){Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue})
    $events=0;foreach($file in $files){$events+=@([IO.File]::ReadLines($file.FullName)).Count}
    [ordered]@{present=($files.Count -gt 0);files=$files.Count;events=$events}
}
function Get-SBSetupFeatureStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BrainRoot,[string]$HomeValue=$env:SECONDBRAIN_HOME,[string]$SettingsPath,[object[]]$Ides,[object[]]$Bindings,[hashtable]$Config,[string]$StateRoot,[hashtable]$ClientSettingsPaths)
    $brain=[IO.Path]::GetFullPath($BrainRoot)
    if(!$SettingsPath){$SettingsPath=Get-SBTraceSettingsPath}
    $features=@()
    $homeSet=[bool]$HomeValue
    $features+=New-SBFeature 'environment' $(if($homeSet){'enabled'}else{'available'}) $(if($homeSet){'SECONDBRAIN_HOME set'}else{'SECONDBRAIN_HOME not set'}) 'pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -Interactive -RegisterEnvironment' @('workstation-activated') 'low' (!$homeSet) 'setupstatus.env.reason'
    foreach($ide in @($Ides)){
        $configured=[bool]$ide.mcpConfigured
        $adapter=[string]$ide.adapter
        $target=$null
        foreach($pair in @(@('claude-code','claude-code'),@('codex','codex'),@('cursor','cursor'),@('antigravity','antigravity'),@('windsurf','windsurf'),@('vscode','vscode'),@('code','vscode'),@('claude','claude'))){if($adapter -match $pair[0]){$target=$pair[1];break}}
        if(!$target){$features+=New-SBFeature 'mcp' 'unsupported' ('no MCP target for '+$ide.name) $null @() 'low' $false $null $ide.name;continue}
        $features+=New-SBFeature 'mcp' $(if($configured){'enabled'}else{'available'}) ($ide.name+' mcpConfigured='+$configured) ('pwsh -NoProfile -File scripts/mcp-server.ps1 -Pair -Target '+$target) @() 'medium' (!$configured) 'setupstatus.mcp.reason' $ide.name
    }
    $hasClaudeCode=@($Ides|Where-Object {[string]$_.adapter -match 'claude-code' -or [string]$_.name -match 'Claude Code'}).Count -gt 0
    if($hasClaudeCode){
        $state=try{Get-SBTraceHookState $brain $SettingsPath}catch{$null}
        $installed=[bool]($state -and $state.installed)
        $features+=New-SBFeature 'trace-hook' $(if($state){$(if($installed){'enabled'}else{'available'})}else{'blocked'}) ('settings '+$SettingsPath) 'pwsh -NoProfile -File scripts/trace.ps1 -InstallHook' @() 'low' (!$installed -and [bool]$state) 'setupstatus.trace.reason' 'claude-code'
        $resourcesInstalled=$false
        if($state -and $state.settings.ContainsKey('hooks') -and $state.settings.hooks -is [Collections.IDictionary] -and $state.settings.hooks.ContainsKey('SessionStart')){
            $resourcesInstalled=$null -ne (ConvertTo-Json $state.settings.hooks.SessionStart -Depth 8 | Select-String -SimpleMatch 'resources-hook.ps1')
        }
        $features+=New-SBFeature 'resources-hook' $(if($resourcesInstalled){'enabled'}else{'available'}) 'SessionStart entry in Claude Code settings' 'pwsh -NoProfile -File scripts/resources-hook.ps1 -ShowConfiguration' @('resources-registry') 'low' (!$resourcesInstalled -and (Test-Path -LiteralPath (Join-Path $brain 'shared/authoritative-sources/entries'))) 'setupstatus.resources.reason' 'claude-code'
    }
    foreach($client in @('codex','antigravity')){
        if(@($Ides|Where-Object {[string]$_.adapter -match $client}).Count -eq 0){continue}
        $clientPath=if($ClientSettingsPaths -and $ClientSettingsPaths.ContainsKey($client)){[string]$ClientSettingsPaths[$client]}else{$null}
        $clientState=try{Get-SBClientHookStatus $brain $client $clientPath}catch{$null}
        foreach($name in 'trace-hook','resources-hook'){
            $entry=if($clientState){@($clientState.hooks|Where-Object {$_.hook -eq $name})[0]}else{$null}
            $on=[bool]($entry -and $entry.installed)
            $features+=New-SBFeature $name $(if(!$clientState){'blocked'}elseif($on){'enabled'}else{'available'}) $(if($clientState){'settings '+$clientState.settingsPath}else{'settings file unreadable'}) ('pwsh -NoProfile -File scripts/client-hooks.ps1 -Install -Client '+$client+' -Hook '+$name) @() 'low' ($clientState -and !$on -and ($name -eq 'trace-hook' -or (Test-Path -LiteralPath (Join-Path $brain 'shared/authoritative-sources/entries')))) $(if($name -eq 'trace-hook'){'setupstatus.clienttrace.reason'}else{'setupstatus.resources.reason'}) $client
        }
    }
    foreach($ide in @($Ides|Where-Object {[string]$_.adapter -eq 'manual' -and [string]$_.name -match 'account instructions'})){
        # No file to deploy: verified only when the map holds a selected entry whose observed hash equals the approved text.
        $verified=$false
        if($StateRoot){
            $mapPath=Join-Path $StateRoot 'ide-map.json';$textPath=Join-Path $StateRoot 'istruzioni-globali.md'
            if((Test-Path -LiteralPath $mapPath) -and (Test-Path -LiteralPath $textPath)){
                $map=Read-SBJson $mapPath $null;$hash=Get-SBTextHash ((Read-SBText $textPath).Trim())
                $verified=@($map.ides|Where-Object {$_.name -eq $ide.name -and (!$_.ContainsKey('selected') -or $_.selected) -and $_.ContainsKey('observedHash') -and [string]$_.observedHash -ceq $hash}).Count -gt 0
            }
        }
        $features+=New-SBFeature 'manual-directives' $(if($verified){'enabled'}else{'blocked'}) $(if($verified){'observed hash matches the approved text'}else{'no valid observation of the approved global directives'}) ('pwsh -NoProfile -File scripts/secondbrain.ps1 -Setup -IdeAccount "'+$ide.name+'|<alias>"') @('workstation-activated') 'low' (!$verified) 'setupstatus.account.reason' ([string]$ide.name)
    }
    foreach($binding in @($Bindings)){
        $path=[string]$binding.path
        if(!$path -or !(Test-Path -LiteralPath $path)){continue}
        $remote=$false
        try{$top=(& git -C $path rev-parse --show-toplevel 2>$null);if($LASTEXITCODE -eq 0 -and [IO.Path]::GetFullPath([string]$top).TrimEnd('','/') -ieq [IO.Path]::GetFullPath($path).TrimEnd('','/')){$remote=@(& git -C $path remote 2>$null).Count -gt 0}}catch{$remote=$false}
        $hookFile=Join-Path $path '.git/hooks/pre-push'
        $hookOn=(Test-Path -LiteralPath $hookFile -PathType Leaf) -and ([IO.File]::ReadAllText($hookFile) -match 'SecondBrain pre-push hook')
        $features+=New-SBFeature 'publication-hook' $(if($hookOn){'enabled'}elseif($remote){'available'}else{'unsupported'}) ('pre-push in '+$path) ('pwsh -NoProfile -File scripts/publication.ps1 -InstallHook -RepositoryPath "'+$path+'"') @('SECONDBRAIN_HOME') 'low' ($remote -and !$hookOn) 'setupstatus.publication.reason' ([string]$binding.identity)
        $gitRecord=$null;$bindingDossier=Resolve-SBBindingDossier $brain $binding;if($bindingDossier){$recordPath=Join-Path $brain ([string]$bindingDossier+'/repository.json');if(Test-Path -LiteralPath $recordPath -PathType Leaf){try{$gitRecord=Read-SBJson $recordPath $null}catch{$gitRecord=$null}}}
        $gitUpdate=Get-SBGitUpdate $gitRecord
        $features+=New-SBFeature 'git-update' $(if($gitUpdate.confirmed){'enabled'}else{'available'}) ('gitUpdate '+$gitUpdate.mode+' on '+$gitUpdate.branch+$(if($gitUpdate.confirmed){''}else{' (proposed default, not confirmed)'})) ('pwsh -NoProfile -File scripts/para.ps1 -SetGitUpdate -GitMode '+$gitUpdate.mode+' -GitBranch '+$gitUpdate.branch+' -Only "'+[string]$binding.identity+'"') @('workstation-activated') 'low' $false 'setupstatus.gitupdate.reason' ([string]$binding.identity)
        $launcher=Join-Path $path '.secondbrain/run-tasks.ps1'
        $launcherOn=Test-Path -LiteralPath $launcher -PathType Leaf
        $features+=New-SBFeature 'task-launcher' $(if($launcherOn){'enabled'}else{'available'}) ('launcher in '+$path) ('pwsh -NoProfile -File scripts/install-task-launcher.ps1 -Repository '+[string]$binding.identity) @('SECONDBRAIN_HOME') 'medium' $false 'setupstatus.launcher.reason' ([string]$binding.identity)
    }
    $activity=$Config -and $Config.ContainsKey('activityLogEnabled') -and [bool]$Config.activityLogEnabled
    $features+=New-SBFeature 'activity-register' $(if($activity){'enabled'}else{'available'}) 'activityLogEnabled in the host configuration' 'edit the host configuration (explicit, with privacy notice)' @('privacy-notice','retention') 'high' $false 'setupstatus.activity.reason'
    @($features)
}
function Get-SBSetupVerification([string]$StateRoot) {
    # Receipts of loading and live tool operation, kept apart from the written configuration: {entries:[{id,scope,loaded,verified,at}]}.
    $path=if($StateRoot){Join-Path $StateRoot 'setup-verification.json'}else{$null}
    $entries=@()
    if($path -and (Test-Path -LiteralPath $path -PathType Leaf)){try{$data=Read-SBJson $path $null;if($data -and $data.ContainsKey('entries')){$entries=@($data.entries)}}catch{$entries=@()}}
    $entries
}
function Add-SBFeatureStates {
    # Three separate states per feature: written (configuration present), loaded (a client session read it), verified (a live tool call worked).
    param([object[]]$Features,[object[]]$Receipts=@())
    foreach($feature in @($Features)){
        $receipt=@($Receipts|Where-Object {[string]$_.id -eq [string]$feature.id -and [string]$_.scope -eq [string]$feature.scope}|Select-Object -First 1)
        $written=[string]$feature.state -eq 'enabled'
        $loaded=if(!$written){'not-applicable'}elseif($receipt -and [bool]$receipt.loaded){'confirmed'}else{'unverified'}
        $verified=if(!$written){'not-applicable'}elseif($receipt -and [bool]$receipt.verified){'confirmed'}else{'unverified'}
        $feature['states']=[ordered]@{written=$written;loaded=$loaded;verified=$verified}
        $feature
    }
}
function Get-SBSetupWizardStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BrainRoot,[string]$WorkspacePath,[string]$SettingsPath)
    $brain=[IO.Path]::GetFullPath($BrainRoot)
    $configPath=Get-SBHostConfigPath $brain
    $activated=Test-Path -LiteralPath $configPath -PathType Leaf
    $config=if($activated){Read-SBJson $configPath @{}}else{@{}}
    $bindings=if($config.ContainsKey('bindings')){@($config.bindings)}else{@()}
    $detected=@(Get-SBIDEDetection $WorkspacePath)
    $features=if($activated){@(Get-SBSetupFeatureStatus -BrainRoot $brain -SettingsPath $SettingsPath -Ides $detected -Bindings $bindings -Config $config -StateRoot (Split-Path $configPath))}else{@()}
    # Recommended features first (stable order otherwise), a per-id summary and the meaning of the exit code.
    $features=@(Add-SBFeatureStates $features @(Get-SBSetupVerification (Split-Path $configPath)))
    $features=@($features|Sort-Object @{Expression={if($_.recommended){0}else{1}}} -Stable)
    $progressPath=Join-Path (Split-Path $configPath) 'setup-progress.json'
    $progress=if($activated -and (Test-Path -LiteralPath $progressPath -PathType Leaf)){try{Read-SBJson $progressPath $null}catch{$null}}else{$null}
    $doneSteps=@(if($progress){$progress.steps|ForEach-Object {[string]$_.step}})
    $interrupted=[bool]($progress -and $progress.status -eq 'in-progress')
    $resume=[ordered]@{interrupted=$interrupted;completed=@($doneSteps);next=$(if($interrupted){@('discovery','selection','activation','mcp','sync','report')|Where-Object {$_ -notin $doneSteps}|Select-Object -First 1}else{$null})}
    $recommended=@($features|Where-Object {$_.recommended}|ForEach-Object {$_.id+$(if($_.scope){':'+$_.scope}else{''})})
    $byId=[ordered]@{}
    foreach($group in @($features|Group-Object {$_['id']})){$byId[$group.Name]=[ordered]@{total=$group.Count;recommended=@($group.Group|Where-Object {$_.recommended}).Count;enabled=@($group.Group|Where-Object {$_.state -eq 'enabled'}).Count}}
    $exit=if(!$activated){[ordered]@{code=1;reason=(Get-SBMessage 'setupstatus.exit.inactive')}}elseif($recommended.Count){[ordered]@{code=1;reason=(Get-SBMessage 'setupstatus.exit.recommended' @($recommended.Count))}}else{[ordered]@{code=0;reason=(Get-SBMessage 'setupstatus.exit.ok')}}
    [ordered]@{
        schemaVersion=1;hostId=(Get-SBHostId);activated=$activated
        blocked=$(if($activated){$null}else{Get-SBMessage 'setupstatus.blocked.inactive'})
        ides=@($detected|ForEach-Object {[ordered]@{name=$_.name;adapter=$_.adapter;confidence=$_.confidence;mcpConfigured=$_.mcpConfigured;scopes=@($_.scopes)}})
        usage=(Get-SBTraceUsage $brain)
        resume=$resume
        summary=[ordered]@{features=$features.Count;written=@($features|Where-Object {$_.states.written}).Count;loaded=@($features|Where-Object {$_.states.loaded -eq 'confirmed'}).Count;verified=@($features|Where-Object {$_.states.verified -eq 'confirmed'}).Count;recommended=$recommended.Count;byId=$byId}
        exit=$exit
        features=$features
        recommended=$recommended
    }
}
Export-ModuleMember -Function @('Get-SBSetupVerification','Add-SBFeatureStates','Get-SBTraceUsage','Get-SBSetupFeatureStatus','Get-SBSetupWizardStatus')
