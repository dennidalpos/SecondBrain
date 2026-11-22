#requires -Version 7.5
[CmdletBinding(DefaultParameterSetName='Approve')]
param(
    [Parameter(Mandatory,ParameterSetName='Approve')][switch]$Approve,
    [Parameter(Mandatory,ParameterSetName='Approve')][string]$PlanPath,
    [Parameter(Mandatory,ParameterSetName='Approve')][string]$ExpectedPlanHash,
    # Grant (#707): lets the agent submit task.status, task.update (status, reason, evidence), non-autonomous task.new, memory.append, activity.append and history.save for one repository. -Hours 0 (default) is standing until revoked.
    [Parameter(Mandatory,ParameterSetName='Grant')][switch]$Grant,
    [Parameter(Mandatory,ParameterSetName='Revoke')][switch]$Revoke,
    [Parameter(Mandatory,ParameterSetName='Grants')][switch]$Grants,
    [Parameter(Mandatory,ParameterSetName='Grant')][Parameter(Mandatory,ParameterSetName='Revoke')][string]$Repository,
    [Parameter(ParameterSetName='Grant')][ValidateRange(0,72)][int]$Hours=0,
    [Parameter(Mandatory,ParameterSetName='Approve')][Parameter(Mandatory,ParameterSetName='Grant')][string]$Authorization,
    [Parameter(Mandatory,ParameterSetName='Approve')][Parameter(Mandatory,ParameterSetName='Grant')][Parameter(Mandatory,ParameterSetName='Revoke')][string]$SessionId,
    [string]$ConfigPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.McpWrites.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'mcpwritecli.size' = @{ en = 'Plan exceeds the 256 KiB limit' }
}
$lock=$null
try {
    $brain=(Get-SBBrainRootPath)
    if($Grants){
        ConvertTo-SBJson (Get-SBMcpWriteGrants $brain $ConfigPath)
    }else{
        $config=Read-SBConfiguration $ConfigPath
        $lock=Enter-SBOperation $config $SessionId
        if($Grant){
            ConvertTo-SBJson (New-SBMcpWriteGrant $brain $ConfigPath $Repository $Hours $Authorization $SessionId)
        }elseif($Revoke){
            ConvertTo-SBJson (Revoke-SBMcpWriteGrant $brain $ConfigPath $Repository $SessionId)
        }else{
            Assert-SBPlainPath $PlanPath
            if((Get-Item -LiteralPath $PlanPath).Length -gt 256KB){throw (New-SBError 'mcpwritecli.size')}
            $plan=Read-SBJson $PlanPath $null
            ConvertTo-SBJson (Approve-SBMcpWritePlan $brain $ConfigPath $plan $ExpectedPlanHash $Authorization $SessionId)
        }
    }
}catch{
    if(Test-SBWriteDeniedError $_){Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters;exit 4}
    if(Test-SBBusyError $_){[Console]::Error.WriteLine($_.Exception.Message);exit 3}
    Write-Error $_ -ErrorAction Continue;exit 2
}finally{Exit-SBOperation $lock}
