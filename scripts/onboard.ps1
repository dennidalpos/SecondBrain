#requires -Version 7.5
<#
.SYNOPSIS
sb onboard: lean registration of one repository (binding, dossier with brief, context, memory, tracker and directives). Only the managed block is written to the repository.
.DESCRIPTION
Previews by default and changes nothing. With -Apply it records the repository in the local allowlist and activates it.
.EXAMPLE
pwsh -NoProfile -File scripts/onboard.ps1 -Path D:\Projects\my-product
.EXAMPLE
pwsh -NoProfile -File scripts/onboard.ps1 -Path D:\Projects\my-product -Customer Acme -Apply
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path,[string]$Customer='',[switch]$Apply,[string]$SessionId)
$ErrorActionPreference='Stop'
$arguments=@('-AddRepo',$Path)
if($Customer){$arguments+=@('-Customer',$Customer)}
if($Apply){$arguments+='-ApplyAdd'}
if($SessionId){$arguments+=@('-SessionId',$SessionId)}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'secondbrain.ps1') @arguments
exit $LASTEXITCODE
