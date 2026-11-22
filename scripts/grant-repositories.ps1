#requires -Version 7.5
<#
.SYNOPSIS
Issues the standing MCP write grant to every bound repository that has none (owner action; previews by default).
.DESCRIPTION
For each active binding with a remote identity and no active grant it opens a write session for that repository, runs mcp-write.ps1 -Grant and ends the session.
Without -Apply it only lists what it would do. Existing active grants are left alone; mcp-write.ps1 -Revoke ends one.
.EXAMPLE
pwsh -NoProfile -File scripts/grant-repositories.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/grant-repositories.ps1 -Apply
#>
[CmdletBinding()]
param([switch]$Apply,[string]$ConfigPath,[string[]]$Only=@())
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.McpWrites.psm1')
$brain=Get-SBBrainRootPath
$config=Read-SBConfiguration -ConfigPath $ConfigPath -BrainRoot $brain -ReadOnly
$active=@{}
foreach($g in @((Get-SBMcpWriteGrants $brain $ConfigPath).grants)){if($g.state -eq 'active'){$active[$g.repository]=$true}}
$identities=@($config.bindings|ForEach-Object {[string]$_.identity}|Where-Object {$_ -and $_ -cnotlike 'local*'}|Sort-Object -Unique)
if($Only.Count){$identities=@($identities|Where-Object {$_ -in $Only})}
$results=@()
foreach($identity in $identities){
    if($active.ContainsKey($identity)){$results+=[pscustomobject]@{repository=$identity;result='already-granted'};continue}
    if(!$Apply){$results+=[pscustomobject]@{repository=$identity;result='would-grant'};continue}
    $session=$null
    try{
        $session=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'access.ps1') -Start -Mode Write -Client Owner -Repository $identity | ConvertFrom-Json
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'mcp-write.ps1') -Grant -Repository $identity -SessionId $session.sessionId -Authorization 'Standing grant issued by the owner through grant-repositories.ps1' | Out-Null
        $results+=[pscustomobject]@{repository=$identity;result=$(if($LASTEXITCODE -eq 0){'granted'}else{"failed-exit-$LASTEXITCODE"})}
    }catch{
        $results+=[pscustomobject]@{repository=$identity;result='failed: '+$_.Exception.Message}
    }finally{
        if($session){& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'access.ps1') -End -SessionId $session.sessionId | Out-Null}
    }
}
$results|Format-Table -AutoSize|Out-String|Write-Output
if(!$Apply){Write-Output 'Preview only: add -Apply to issue the grants.'}
