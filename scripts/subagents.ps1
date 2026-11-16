#requires -Version 7.5
<#
.SYNOPSIS
Subagent definitions (F8): validation, inherited permissions and per-client export.
.DESCRIPTION
Definitions live in <dossier>/subagents/<name>.json: schema 1 (role, context, permissions, MCP tools) or schema 2, which adds id, revision, status, cards, output and bounds (docs/riferimento/asset-contracts.md section 4).
-Operation Validate: checks every definition and resolves its cards against direttive/prompts/catalog.json (read-only).
-Operation Resolve: shows effective permissions against a parent (-ParentTools, -ParentWrite); requesting more than the parent is an error. Also reports lifecycle, output, bounds and resolved cards.
-Operation Create|Edit|Revise|Retire (#622): authoring and lifecycle of schema 2 definitions; preview unless -Apply. Create and Revise take -DefinitionPath (JSON), Edit changes only description and context, Retire takes -Status deprecated|retired and optionally -ReplacedBy. A breaking change is refused: create a new definition and retire the old one.
-Operation Export: renders definitions for -Client into -OutputPath (under .runtime); preview unless -Apply. Never writes into a checkout.
Native formats: claude-code (.claude/agents/*.md), codex (.codex/agents/*.toml), gemini (.gemini/agents/*.md); other clients get the normalized JSON. Each file reports `unsupported` (definition fields the client cannot represent) and `enforcement` (what the client enforces versus what is only declared). -Probe adds the installed CLI's status and version.
A definition carries no authorization; writes stay behind the parent's reviewed MCP write path.
.EXAMPLE
pwsh -NoProfile -File scripts/subagents.ps1 -Operation Export -Repository github.com/my-org/my-product -Client claude-code -OutputPath .runtime/export/agents
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Validate','Resolve','Export','Create','Edit','Revise','Retire')][string]$Operation,
    [Parameter(Mandatory)][string]$Repository,
    [string[]]$ParentTools,[switch]$ParentWrite,
    [ValidateSet('claude-code','codex','gemini','antigravity','vscode','android-studio','claude','cursor','windsurf','continue','jetbrains')][string]$Client,[switch]$Probe,
    [string]$OutputPath,[string]$ConfigPath,[string]$SessionId,[switch]$Apply,
    [string]$Name,[string]$DefinitionPath,[ValidateSet('deprecated','retired')][string]$Status,[string]$ReplacedBy
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($m in 'Core','Access','Host','Para','Knowledge','Subagents'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{'subagent.cli'=@{ en = 'Subagents: missing or out-of-scope parameter ({0})' }}
$brain=Get-SBBrainRootPath
if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'subagent.cli' @('repository'))}
$dossier=Resolve-SBParaPath $brain (Resolve-SBWorkingDossier $brain $Repository)
$catalog=Read-SBSubagentCatalog $brain
$tools=Get-SBSubagentTools
$parent=@{tools=@(if($PSBoundParameters.ContainsKey('ParentTools')){$ParentTools}else{$tools.read});write=[bool]$ParentWrite}
if($Operation -eq 'Validate'){
    $entries=@(Read-SBSubagentDefinitions $dossier $catalog)
    ConvertTo-SBJson (Get-SBSubagentValidateReport $entries);exit 0
}
if($Operation -eq 'Resolve'){
    $entries=@(Read-SBSubagentDefinitions $dossier $catalog)
    ConvertTo-SBJson (Get-SBSubagentResolveReport $entries $parent);exit 0
}
if($Operation -in @('Create','Edit','Revise','Retire')){
    $definition=$null
    if($Operation -in @('Create','Edit','Revise')){
        if(!$DefinitionPath){throw (New-SBError 'subagent.cli' @('definitionPath'))}
        Assert-SBPlainPath $DefinitionPath
        try{$definition=(Read-SBText $DefinitionPath)|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{throw (New-SBError 'subagent.invalid' @('json'))}
        if($Operation -ne 'Create' -and !$Name -and $definition -is [Collections.IDictionary]){$Name=[string]$definition.name}
    }
    $config=Read-SBConfiguration $ConfigPath -ReadOnly:(!$Apply)
    $owned=$null;$lock=$null
    try{
        if($Apply -and !$SessionId){$owned=& (Join-Path $PSScriptRoot 'access.ps1') -Start -Mode Write -Client subagents -Repository $Repository -ConfigPath $config.configPath|ConvertFrom-Json -AsHashtable;$SessionId=$owned.sessionId}
        $lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)
        $plan=Get-SBSubagentManagePlan -Dossier $dossier -Catalog $catalog -Action $Operation -Definition $definition -Name $Name -Status $Status -ReplacedBy $ReplacedBy
        if($Apply){[void](Save-SBSubagentManagePlan $plan $config.backupRoot)}
        ConvertTo-SBJson (Get-SBSubagentManageView $plan ([bool]$Apply))
    }finally{
        if($lock){Exit-SBOperation $lock}
        if($owned){& (Join-Path $PSScriptRoot 'access.ps1') -End -SessionId $SessionId -ConfigPath $config.configPath|Out-Null}
    }
    exit 0
}
if(!$Client){throw (New-SBError 'subagent.cli' @('client'))}
if(!$OutputPath){throw (New-SBError 'subagent.cli' @('outputPath'))}
$scope=[IO.Path]::GetFullPath((Join-Path $brain '.runtime')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$root=[IO.Path]::GetFullPath($OutputPath,$brain)
if(!$root.StartsWith($scope,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'subagent.cli' @('outputPath'))}
$config=Read-SBConfiguration $ConfigPath -ReadOnly:(!$Apply)
$owned=$null;$lock=$null
try{
    if($Apply -and !$SessionId){$owned=& (Join-Path $PSScriptRoot 'access.ps1') -Start -Mode Write -Client subagents -Repository $Repository -ConfigPath $config.configPath|ConvertFrom-Json -AsHashtable;$SessionId=$owned.sessionId}
    $lock=Enter-SBOperation $config $SessionId -ReadOnly:(!$Apply)
    $capabilities=$null
    if($Probe){
        $providers=@{'claude-code'='claude';codex='codex';gemini='gemini'}
        if($providers.ContainsKey($Client)){
            Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAdapters.psm1')
            $capabilities=Get-SBAgentCapabilities -Provider $providers[$Client] -BrainRoot $brain
        }
    }
    ConvertTo-SBJson (Export-SBSubagents $dossier $Client $parent $root $config.backupRoot -Apply:$Apply -Catalog $catalog -Capabilities $capabilities)
}finally{
    if($lock){Exit-SBOperation $lock}
    if($owned){& (Join-Path $PSScriptRoot 'access.ps1') -End -SessionId $SessionId -ConfigPath $config.configPath|Out-Null}
}
