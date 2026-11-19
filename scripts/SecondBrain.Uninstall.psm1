#requires -Version 7.5
# sb uninstall (#727): inventory of what SecondBrain installed and removal of only that. User content is never touched:
# managed blocks are removed by their markers, the launcher only when it is byte-identical to a SecondBrain template.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'uninstall.data.authorization' = @{ en = '-RemoveData needs -Authorization with the exact text: delete dossiers' }
    'uninstall.step.unknown' = @{ en = 'Unknown uninstall step: {0}. Steps: repositories, launchers, ide-blocks, mcp, hooks, environment, data, shared, runtime' }
    'uninstall.runtime.authorization' = @{ en = 'The runtime step needs -RemoveRuntime and -RuntimeAuthorization with the exact text: delete runtime and backups' }
    'uninstall.mcp.verify' = @{ en = 'MCP entry removal did not verify for {0}: the file is left unchanged' }
}

$script:SBUninstallBlocks=@(
    @{name='global';pattern='(?s)\r?\n?<!-- secondbrain:global:begin -->.*?<!-- secondbrain:global:end -->\r?\n?'},
    @{name='repository';pattern='(?s)\r?\n?<!-- secondbrain:repository:begin -->.*?<!-- secondbrain:repository:end -->\r?\n?'},
    @{name='pointer';pattern='(?s)\r?\n?<!-- secondbrain:pointer:begin -->.*?<!-- secondbrain:pointer:end -->\r?\n?'}
)

# Which managed blocks a text contains (names).
function Get-SBUninstallBlockNames([string]$Text) {
    @($script:SBUninstallBlocks|Where-Object {$Text -match $_.pattern}|ForEach-Object {$_.name})
}
# The text without any managed block; user text is kept as it is.
function Remove-SBUninstallBlocks([string]$Text) {
    $result=$Text
    foreach($block in $script:SBUninstallBlocks){$result=[regex]::Replace($result,$block.pattern,"`n")}
    $result.Trim()
}

# Files that carry SecondBrain markers: IDE instruction files and the instruction files of the bound checkouts.
function Get-SBUninstallInstructionFiles($Config,[object[]]$Ides=@()) {
    $files=[Collections.Generic.List[string]]::new()
    foreach($ide in @($Ides)){
        if($ide -is [System.Collections.IDictionary]){$mode=$ide['mode'];$instructions=$ide['instructions']}else{$mode=$ide.mode;$instructions=$ide.instructions}
        if($mode -eq 'file' -and $instructions -and !$files.Contains([string]$instructions)){$files.Add([string]$instructions)}
    }
    foreach($binding in @($Config.bindings)){
        if(!$binding.path){continue}
        foreach($name in 'AGENTS.md','CLAUDE.md','GEMINI.md'){
            $path=Join-Path ([string]$binding.path) $name
            if(!$files.Contains($path)){$files.Add($path)}
        }
    }
    @($files|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
}

# Preview data: every item to remove and every item that stays.
function Get-SBUninstallInventory($Config,[string]$BrainRoot,[object[]]$Ides=@()) {
    $remove=@();$keep=@()
    foreach($binding in @($Config.bindings)){
        $remove+=[ordered]@{kind='repository';target=[string]$binding.identity;path=[string]$binding.path;action='sb offboard: binding, managed blocks and pointers removed, open tasks written to TASKS.md, dossier saved first'}
        if($binding.path){
            $launcher=Join-Path ([string]$binding.path) '.secondbrain/run-tasks.ps1'
            if(Test-Path -LiteralPath $launcher -PathType Leaf){$remove+=[ordered]@{kind='launcher';target=$launcher;path=$launcher;action='removed only when identical to a SecondBrain template'}}
        }
    }
    foreach($file in @(Get-SBUninstallInstructionFiles $Config $Ides)){
        $names=@(Get-SBUninstallBlockNames ([IO.File]::ReadAllText($file)))
        if($names.Count){$remove+=[ordered]@{kind='managed-block';target=($names -join ',');path=$file;action='managed block removed by its markers, the rest of the file is kept'}}
    }
    foreach($client in 'claude-code','codex','antigravity'){$remove+=[ordered]@{kind='hook';target=$client;path='';action="client-hooks.ps1 -Uninstall -Client $client"}}
    $env=[Environment]::GetEnvironmentVariable('SECONDBRAIN_HOME','User')
    if($env){$remove+=[ordered]@{kind='environment';target='SECONDBRAIN_HOME';path='';action='user environment variable removed'}}
    $remove+=[ordered]@{kind='data';target='repos/ and workstation/ dossiers';path=$BrainRoot;action='only with -RemoveData and the authorization text; dossier contents are deleted, README files stay'}
    $remove+=[ordered]@{kind='shared';target='shared/ contents';path=(Join-Path $BrainRoot 'shared');action='step shared, only with -RemoveData and the same authorization text as data; contents are deleted, README files stay'}
    $remove+=[ordered]@{kind='runtime';target='.runtime folder with every backup saved by this command';path=(Join-Path $BrainRoot '.runtime');action='step runtime, last, only with -RemoveRuntime and -RuntimeAuthorization "delete runtime and backups"; backups are deleted with it and cannot be restored'}
    foreach($ide in @($Ides)){
        $mcp=if($ide -is [System.Collections.IDictionary]){$ide['mcpConfigPath']}else{$ide.mcpConfigPath}
        if(!$mcp){continue}
        if([string]$mcp -in @(Get-SBUninstallMcpFiles @($ide))){
            if(!@($remove|Where-Object {$_.kind -eq 'mcp-entry' -and $_.path -ceq [string]$mcp}).Count){$remove+=[ordered]@{kind='mcp-entry';target='secondbrain server';path=[string]$mcp;action='step mcp: the secondbrain server entry is removed after a verified backup; other servers and keys stay'}}
        }
        elseif(!@($keep|Where-Object {$_.kind -eq 'mcp-config' -and $_.path -ceq [string]$mcp}).Count){$keep+=[ordered]@{kind='mcp-config';path=[string]$mcp;reason='no secondbrain server entry found in this client configuration'}}
    }
    $keep+=[ordered]@{kind='checkout';path=$BrainRoot;reason='the SecondBrain checkout itself (scripts, docs, README files); delete the folder yourself if you want it gone'}
    $keep+=[ordered]@{kind='user-content';path='';reason='all text outside the managed blocks, product code and any launcher that differs from a template'}
    [ordered]@{remove=$remove;keep=$keep}
}

# MCP entry of the secondbrain server in a client configuration (#736). JSON clients keep it under mcpServers or servers (also per project in
# ~/.claude.json), Codex keeps TOML sections [mcp_servers.secondbrain] and [mcp_servers.secondbrain.*]. Pure: returns the text without the
# entry, or $null when there is none. Other servers and every other key are kept.
function Remove-SBMcpEntry([string]$Text,[string]$Path) {
    if([string]::IsNullOrWhiteSpace($Text)){return $null}
    if($Path -match '\.toml$'){
        $pattern = '(?ms)^\[mcp_servers\.secondbrain(?:\.[^\]\r\n]*)?\][^\r\n]*\r?\n.*?(?=^\[|\z)'
        if(![regex]::IsMatch($Text,$pattern)){return $null}
        return ([regex]::Replace([regex]::Replace($Text,$pattern,''),'(\r?\n){3,}',"`n`n")).TrimEnd()+"`n"
    }
    try{$document=$Text|ConvertFrom-Json -Depth 100}catch{return $null}
    if($document -isnot [pscustomobject]){return $null}
    $found=$false
    $containers=[Collections.Generic.List[object]]::new()
    foreach($key in 'mcpServers','servers'){if($document.PSObject.Properties[$key]){$containers.Add($document.$key)}}
    if($document.PSObject.Properties['projects'] -and $document.projects -is [pscustomobject]){
        foreach($project in $document.projects.PSObject.Properties){
            if($project.Value -is [pscustomobject] -and $project.Value.PSObject.Properties['mcpServers']){$containers.Add($project.Value.mcpServers)}
        }
    }
    foreach($container in $containers){
        if($container -is [pscustomobject] -and $container.PSObject.Properties['secondbrain']){$container.PSObject.Properties.Remove('secondbrain');$found=$true}
    }
    if(!$found){return $null}
    ($document|ConvertTo-Json -Depth 100)+"`n"
}
# Client MCP configuration files that still hold a secondbrain entry.
function Get-SBUninstallMcpFiles([object[]]$Ides=@()) {
    $paths=@()
    foreach($ide in @($Ides)){
        $mcp=if($ide -is [System.Collections.IDictionary]){$ide['mcpConfigPath']}else{$ide.mcpConfigPath}
        if($mcp -and [IO.File]::Exists([string]$mcp) -and [string]$mcp -notin $paths -and $null -ne (Remove-SBMcpEntry ([IO.File]::ReadAllText([string]$mcp)) ([string]$mcp))){$paths+=[string]$mcp}
    }
    $paths
}

# Instruction files that still carry a SecondBrain marker (scan after apply).
function Find-SBUninstallResidue($Config,[object[]]$Ides=@()) {
    @(@(Get-SBUninstallInstructionFiles $Config $Ides|Where-Object {([IO.File]::ReadAllText($_)) -match '<!-- secondbrain:'})+@(Get-SBUninstallMcpFiles $Ides))
}

Export-ModuleMember -Function Remove-SBMcpEntry,Get-SBUninstallMcpFiles,Get-SBUninstallBlockNames,Remove-SBUninstallBlocks,Get-SBUninstallInstructionFiles,Get-SBUninstallInventory,Find-SBUninstallResidue
