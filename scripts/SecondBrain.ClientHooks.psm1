#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'clienthooks.client.unknown'  = @{ en = 'Unsupported client "{0}"; supported clients: claude-code, codex, antigravity.' }
    'clienthooks.client.required' = @{ en = 'Specify -Client (claude-code, codex or antigravity).' }
    'clienthooks.hook.unknown'   = @{ en = 'Unsupported hook "{0}"; supported hooks: resources-hook, trace-hook.' }
    'clienthooks.settings.json'   = @{ en = 'The client settings file is not valid JSON; fix or remove it before installing hooks.' }
    'clienthooks.settings.object' = @{ en = 'The client settings file must contain a JSON object.' }
}
# Session hooks per client: resources-hook (session start) and trace-hook (end of turn). memory-cycle-hook has no installer:
# it needs a per-turn permit and a hook entry cannot grant persistence. Entries are recognized by their exact command; other entries stay untouched.
# Client file formats: Claude Code ~/.claude/settings.json, Codex ~/.codex/hooks.json (CODEX_HOME), Antigravity ~/.gemini/settings.json (shared Gemini configuration).
$script:Clients=[ordered]@{
    'claude-code' = @{start='SessionStart';stop='Stop'}
    'codex'       = @{start='SessionStart';stop='Stop'}
    'antigravity' = @{start='SessionStart';stop='AfterAgent'}
}
function Get-SBClientHookClients { @($script:Clients.Keys) }
function Get-SBClientHookSettingsPath([string]$Client) {
    if(!$script:Clients.Contains($Client)){throw (New-SBError 'clienthooks.client.unknown' @($Client))}
    $profileRoot=[Environment]::GetFolderPath('UserProfile')
    switch($Client){
        'claude-code' {Join-Path $profileRoot '.claude/settings.json'}
        'codex' {$home2=$env:CODEX_HOME;if(!$home2){$home2=Join-Path $profileRoot '.codex'};Join-Path $home2 'hooks.json'}
        'antigravity' {Join-Path $profileRoot '.gemini/settings.json'}
    }
}
function Get-SBClientHookDefinition([string]$BrainRoot,[string]$Client,[string]$Hook) {
    if(!$script:Clients.Contains($Client)){throw (New-SBError 'clienthooks.client.unknown' @($Client))}
    $scripts=[IO.Path]::GetFullPath((Join-Path $BrainRoot 'scripts'))
    switch($Hook){
        'resources-hook' {@{hook=$Hook;event=$script:Clients[$Client].start;command='pwsh -NoProfile -File "'+(Join-Path $scripts 'resources-hook.ps1')+'"'}}
        'trace-hook' {
            $command='pwsh -NoProfile -File "'+(Join-Path $scripts 'trace.ps1').Replace('\','/')+'" -Event stop'
            if($Client -ne 'claude-code'){$command+=' -Ide '+$Client}
            @{hook=$Hook;event=$script:Clients[$Client].stop;command=$command}
        }
        default {throw (New-SBError 'clienthooks.hook.unknown' @($Hook))}
    }
}
function Read-SBClientHookSettings([string]$Path) {
    $settings=@{}
    if(Test-Path -LiteralPath $Path -PathType Leaf){
        $text=Read-SBText $Path
        if($text.Trim()){try{$settings=$text|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{throw (New-SBError 'clienthooks.settings.json')}}
    }
    if($settings -isnot [Collections.IDictionary]){throw (New-SBError 'clienthooks.settings.object')}
    $settings
}
function Test-SBClientHookEntry($Settings,[string]$Event,[string]$Command) {
    if(!($Settings.ContainsKey('hooks') -and $Settings.hooks -is [Collections.IDictionary] -and $Settings.hooks.ContainsKey($Event))){return $false}
    foreach($group in @($Settings.hooks[$Event])){
        if($group -is [Collections.IDictionary] -and $group.ContainsKey('hooks')){foreach($hook in @($group.hooks)){if($hook -is [Collections.IDictionary] -and $hook.ContainsKey('command') -and [string]$hook.command -eq $Command){return $true}}}
    }
    $false
}
function Get-SBClientHookStatus([string]$BrainRoot,[string]$Client,[string]$SettingsPath) {
    if(!$SettingsPath){$SettingsPath=Get-SBClientHookSettingsPath $Client}
    $settings=Read-SBClientHookSettings $SettingsPath
    $hooks=@(foreach($name in 'resources-hook','trace-hook'){
        $definition=Get-SBClientHookDefinition $BrainRoot $Client $name
        [ordered]@{hook=$name;event=$definition.event;installed=(Test-SBClientHookEntry $settings $definition.event $definition.command)}
    })
    [ordered]@{client=$Client;settingsPath=$SettingsPath;exists=(Test-Path -LiteralPath $SettingsPath -PathType Leaf);hooks=$hooks}
}
function Set-SBClientHooks([string]$BrainRoot,[string]$BackupRoot,[string]$Client,[string]$SettingsPath,[string[]]$Hooks=@('resources-hook','trace-hook'),[switch]$Remove,[switch]$Apply) {
    if(!$SettingsPath){$SettingsPath=Get-SBClientHookSettingsPath $Client}
    $settings=Read-SBClientHookSettings $SettingsPath
    $hash=Get-SBFileHash $SettingsPath
    $changes=@()
    foreach($name in $Hooks){
        $definition=Get-SBClientHookDefinition $BrainRoot $Client $name
        $event=$definition.event;$command=$definition.command
        $present=Test-SBClientHookEntry $settings $event $command
        if($Remove){
            if(!$present){continue}
            $kept=@()
            foreach($group in @($settings.hooks[$event])){
                if($group -is [Collections.IDictionary] -and $group.ContainsKey('hooks')){
                    $remaining=@(@($group.hooks)|Where-Object {!($_ -is [Collections.IDictionary] -and $_.ContainsKey('command') -and [string]$_.command -eq $command)})
                    if($remaining.Count){$group.hooks=$remaining;$kept+=$group}
                }else{$kept+=$group}
            }
            if($kept.Count){$settings.hooks[$event]=$kept}else{$settings.hooks.Remove($event);if(!$settings.hooks.Count){$settings.Remove('hooks')}}
            $changes+=$name
        }elseif(!$present){
            if(!$settings.ContainsKey('hooks') -or $settings.hooks -isnot [Collections.IDictionary]){$settings.hooks=@{}}
            $groups=if($settings.hooks.ContainsKey($event)){@($settings.hooks[$event])}else{@()}
            $settings.hooks[$event]=@($groups)+@(@{hooks=@(@{type='command';command=$command})})
            $changes+=$name
        }
    }
    $result=[ordered]@{client=$Client;applied=$false;preview=!$Apply;changed=($changes.Count -gt 0);hooks=@($changes);settingsPath=$SettingsPath;grantsWritePermission=$false}
    if(!$Apply -or !$changes.Count){return $result}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $settings))
    [void](Write-SBFile $SettingsPath $bytes $hash $BackupRoot -BackupDirty)
    $result.applied=$true
    $result
}
Export-ModuleMember -Function @('Get-SBClientHookClients','Get-SBClientHookSettingsPath','Get-SBClientHookDefinition','Get-SBClientHookStatus','Set-SBClientHooks')
