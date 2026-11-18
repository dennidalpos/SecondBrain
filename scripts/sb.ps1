#requires -Version 7.5
<#
.SYNOPSIS
Single `sb` entry point: runs the existing SecondBrain scripts through subcommands.
.EXAMPLE
pwsh -NoProfile -File scripts/sb.ps1 help
.EXAMPLE
pwsh -NoProfile -File scripts/sb.ps1 check
.EXAMPLE
pwsh -NoProfile -File scripts/sb.ps1 prompt show session.start
.EXAMPLE
pwsh -NoProfile -File scripts/sb.ps1 runner -RepositoryPath .
#>
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments)][string[]]$Command)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Dispatch.psm1')
$plan=Resolve-SBDispatch @($Command)
if($plan.ContainsKey('help')){
    foreach($entry in @(Get-SBWorkflowCommands)){('{0}  -  {1}' -f $entry.command,$entry.does)}
    exit 0
}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot $plan.script) @($plan.arguments)
exit $LASTEXITCODE
