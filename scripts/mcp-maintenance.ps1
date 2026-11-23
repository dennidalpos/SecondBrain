#requires -Version 7.5
<#
.SYNOPSIS
MCP maintenance: checks which IDE configurations carry the SecondBrain MCP server and realigns the ones that do not.
-Status is read-only. -Realign previews the pairing of every target that is not configured; with -Apply it writes it
through mcp-server.ps1 -Pair -Apply, which saves a backup of each file first. -Handshake also runs the stdio handshake check.
MCP is the preferred channel of sb; when this reports a target as not configured, the CLI scripts remain the fallback.
.EXAMPLE
pwsh -NoProfile -File scripts/mcp-maintenance.ps1 -Status
.EXAMPLE
pwsh -NoProfile -File scripts/mcp-maintenance.ps1 -Status -Handshake
.EXAMPLE
pwsh -NoProfile -File scripts/mcp-maintenance.ps1 -Realign
.EXAMPLE
pwsh -NoProfile -File scripts/mcp-maintenance.ps1 -Realign -Apply -Target codex
Exit codes: 0 every checked target is configured, 1 at least one is not (or the handshake failed), 2 error.
#>
[CmdletBinding(DefaultParameterSetName='Status')]
param(
    [Parameter(ParameterSetName='Status')][switch]$Status,
    [Parameter(Mandatory,ParameterSetName='Realign')][switch]$Realign,
    [Parameter(ParameterSetName='Realign')][switch]$Apply,
    [Parameter(ParameterSetName='Status')][switch]$Handshake,
    [ValidateSet('codex','claude','claude-code','cursor','vscode','antigravity','windsurf','all')][string]$Target='all'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'mcpmaint.target' = @{ en = '{0}: {1}' }
    'mcpmaint.configured' = @{ en = 'configured' }
    'mcpmaint.missing' = @{ en = 'not configured' }
    'mcpmaint.unknown' = @{ en = 'state not readable' }
    'mcpmaint.summary.ok' = @{ en = 'MCP aligned for {0} target(s): use MCP first, CLI only as a fallback.' }
    'mcpmaint.summary.gap' = @{ en = 'MCP not aligned for {0} of {1} target(s): use the CLI scripts for those clients; `sb mcp realign` previews the fix, `sb mcp realign -Apply` writes it.' }
    'mcpmaint.handshake' = @{ en = 'Running the stdio handshake check (a few minutes).' }
    'mcpmaint.handshake.failed' = @{ en = 'Handshake check failed: see the output above.' }
    'mcpmaint.realign.preview' = @{ en = 'Preview of the pairing for {0}; nothing is written (add -Apply to write it, a backup is taken first).' }
    'mcpmaint.realign.applied' = @{ en = 'Pairing written for {0}.' }
    'mcpmaint.realign.none' = @{ en = 'Nothing to realign: every checked target is configured.' }
}
try{
    $allTargets=@('codex','claude','claude-code','cursor','vscode','antigravity','windsurf')
    $targets=if($Target -eq 'all'){$allTargets}else{@($Target)}
    $server=Join-Path $PSScriptRoot 'mcp-server.ps1'
    $states=[ordered]@{}
    foreach($name in $targets){
        $text=(& pwsh -NoProfile -File $server -Pair -Target $name 2>&1|Out-String)
        $states[$name]=if($text -match '=== SecondBrain MCP pairing for .*\[CONFIGURED\]'){'configured'}elseif($text -match '=== SecondBrain MCP pairing for .*\[TO CONFIGURE\]'){'missing'}else{'unknown'}
        Get-SBMessage 'mcpmaint.target' @($name,(Get-SBMessage ('mcpmaint.'+$states[$name])))
    }
    $gaps=@($states.Keys|Where-Object {$states[$_] -ne 'configured'})
    if($Realign){
        if(!$gaps.Count){Get-SBMessage 'mcpmaint.realign.none';exit 0}
        foreach($name in $gaps){
            if($Apply){& pwsh -NoProfile -File $server -Pair -Target $name -Apply;Get-SBMessage 'mcpmaint.realign.applied' @($name)}
            else{Get-SBMessage 'mcpmaint.realign.preview' @($name);& pwsh -NoProfile -File $server -Pair -Target $name}
        }
        exit 0
    }
    if($gaps.Count){Get-SBMessage 'mcpmaint.summary.gap' @($gaps.Count,$states.Count)}else{Get-SBMessage 'mcpmaint.summary.ok' @($states.Count)}
    $failed=[bool]$gaps.Count
    if($Handshake){
        Get-SBMessage 'mcpmaint.handshake'
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-secondbrain-mcp-handshake.ps1') -Target ($targets -join ',')
        if($LASTEXITCODE -ne 0){Get-SBMessage 'mcpmaint.handshake.failed';$failed=$true}
    }
    exit $(if($failed){1}else{0})
}catch{Write-Error $_ -ErrorAction Continue;exit 2}
