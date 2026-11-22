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
param([Parameter(Mandatory)][string]$Path,[string]$Customer='',[switch]$Apply,[string]$SessionId,[switch]$NoGrant)
$ErrorActionPreference='Stop'
$arguments=@('-AddRepo',$Path)
if($Customer){$arguments+=@('-Customer',$Customer)}
if($Apply){$arguments+='-ApplyAdd'}
if($SessionId){$arguments+=@('-SessionId',$SessionId)}
$output=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'secondbrain.ps1') @arguments
$code=$LASTEXITCODE
$output
if($code -ne 0 -or !$Apply -or $NoGrant){exit $code}
# The owner runs this command with -Apply, so onboarding also issues the repository's standing MCP write grant
# (own-dossier operations only, see docs/reference/mcp-writes.md); -NoGrant skips it and mcp-write.ps1 -Revoke ends it.
$identity=$null
try{$identity=[string](($output -join "`n")|ConvertFrom-Json).entry.identity}catch{$identity=$null}
if($identity -and $identity -cnotlike 'local*'){
    $started=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'access.ps1') -Start -Mode Write -Client Onboard -Repository $identity | ConvertFrom-Json
    try{
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'mcp-write.ps1') -Grant -Repository $identity -SessionId $started.sessionId -Authorization 'Standing grant issued by the owner through sb onboard -Apply'
        if($LASTEXITCODE -ne 0){$code=$LASTEXITCODE}
    }finally{
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'access.ps1') -End -SessionId $started.sessionId | Out-Null
    }
}
exit $code
