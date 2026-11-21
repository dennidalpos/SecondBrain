#requires -Version 7.5
<#
.SYNOPSIS
sb install: one command to onboard a new PC. Chains preflight checks, secondbrain.ps1 -Setup and the enrolment of the repositories.
.DESCRIPTION
Previews by default: runs the preflight checks (Windows, Git, roots) and the read-only Setup preview, and changes nothing.
-Apply runs the same Setup with -Yes -Apply, which activates the workstation and enrols the selected repositories. No setup logic lives here.
Every checkout passed in -Roots is selected and enrolled, one Setup run per root. Prints JSON; exit 0 preview or applied, 1 setup not completed, 2 preflight failed.
.EXAMPLE
pwsh -NoProfile -File scripts/install.ps1 -Roots D:\Projects\my-product
.EXAMPLE
pwsh -NoProfile -File scripts/install.ps1 -Roots D:\Projects\my-product -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Roots,
    [switch]$Apply,
    [switch]$NoRegisterEnvironment
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'install.preflight.git' = @{ en = 'Git 2.42 or later was not found on PATH' }
    'install.preflight.os' = @{ en = 'SecondBrain onboarding needs Windows' }
    'install.preflight.root' = @{ en = 'Root not found: {0}' }
}
try{
    $checks=[ordered]@{}
    $checks.windows=[bool]$IsWindows
    $gitText=if(Get-Command git -ErrorAction SilentlyContinue){(& git --version 2>$null)|Out-String}else{''}
    $gitVersion=if($gitText -match '(\d+)\.(\d+)'){[version]('{0}.{1}' -f $Matches[1],$Matches[2])}else{$null}
    $checks.git=[bool]($gitVersion -and $gitVersion -ge [version]'2.42')
    $checks.powershell=$PSVersionTable.PSVersion.ToString()
    $missingRoots=@($Roots|Where-Object {!(Test-Path -LiteralPath $_ -PathType Container)})
    $checks.roots=!$missingRoots.Count
    $failure=if(!$checks.windows){Get-SBMessage 'install.preflight.os'}elseif(!$checks.git){Get-SBMessage 'install.preflight.git'}elseif($missingRoots.Count){Get-SBMessage 'install.preflight.root' @($missingRoots[0])}
    if($failure){
        ConvertTo-SBJson @{stage='preflight';ok=$false;checks=$checks;error=$failure}
        exit 2
    }
    $setup=Join-Path $PSScriptRoot 'secondbrain.ps1'
    $runs=@();$failed=$false
    foreach($root in $Roots){
        $arguments=@('-Setup','-Roots',$root,'-Select',$root)
        if($Apply){$arguments+=@('-Yes','-Apply')}else{$arguments+='-PreviewOnly'}
        if($NoRegisterEnvironment){$arguments+='-NoRegisterEnvironment'}
        $lines=@(& pwsh -NoProfile -File $setup @arguments 2>&1)
        $code=$LASTEXITCODE
        $text=(@($lines|Where-Object {$_ -isnot [Management.Automation.ErrorRecord]}) -join "`n")
        $setupResult=$null;try{$setupResult=$text|ConvertFrom-Json -AsHashtable}catch{Write-Verbose $_.Exception.Message}
        if($code -ne 0){$failed=$true}
        $runs+=@{root=$root;exit=$code;setup=$setupResult}
    }
    ConvertTo-SBJson @{stage=$(if($Apply){'applied'}else{'preview'});ok=!$failed;checks=$checks;runs=$runs}
    if($failed){exit 1};exit 0
}catch{
    Write-Error $_ -ErrorAction Continue
    exit 2
}
