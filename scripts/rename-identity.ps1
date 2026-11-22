#requires -Version 7.5
<#
.SYNOPSIS
Moves a managed repository to another identity (for example a fork). Previews by default.
.DESCRIPTION
The checkout origin must already be the new identity. Changes the dossier repository.json (the old identity becomes an alias), the tracker and archive
references, the workstation binding and the allowlist entry. Other dossiers that still reference the old identity are reported, not edited.
-Apply needs a write session for the dossier (access.ps1 -Start -Mode Write -Repository <old identity>) and an empty pending-writes queue.
Afterwards issue the grant for the new identity (mcp-write.ps1 -Grant or grant-repositories.ps1 -Apply).
.EXAMPLE
pwsh -NoProfile -File scripts/rename-identity.ps1 -From github.com/trustant/trustant -To github.com/dennidalpos/trustant
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$From,[Parameter(Mandatory)][string]$To,[switch]$Apply,[string]$SessionId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1')
try{
    $brain=Get-SBBrainRootPath
    if($Apply -and !$SessionId){throw (New-SBError 'portable.rename.invalid')}
    ConvertTo-SBJson (Rename-SBRepositoryIdentity -BrainRoot $brain -From $From -To $To -Apply:$Apply -SessionId $SessionId)
}catch{
    Write-Error $_ -ErrorAction Continue
    exit 2
}
