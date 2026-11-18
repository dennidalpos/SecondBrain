#requires -Version 7.5
Set-StrictMode -Version Latest
foreach($m in 'Core','Access','Host','Entity','Portable'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'bindings.config.invalid' = @{ en = 'The workstation configuration is not a portable schema 1 file with bindings: nothing to migrate' }
}
# #700: schema migration of the repository bindings in the workstation configuration to the minimal form
# (identity, path, managed block hash; repositoryFiles, remoteIdentity and status only when they carry information).
function Get-SBBindingMigrationPlan {
    param([string]$BrainRoot,[string]$ConfigPath)
    $path=if($ConfigPath){[IO.Path]::GetFullPath($ConfigPath)}else{Get-SBHostConfigPath $BrainRoot}
    $raw=Read-SBJson $path $null
    if($raw -isnot [Collections.IDictionary] -or $raw.schemaVersion -ne 1 -or $raw.mode -ne 'portable' -or !$raw.ContainsKey('bindings')){throw (New-SBError 'bindings.config.invalid')}
    $items=@();$minimal=@()
    foreach($binding in @($raw.bindings)){
        $converted=ConvertTo-SBMinimalBinding $binding
        $dropped=@($binding.Keys|Where-Object {!$converted.ContainsKey($_)}|Sort-Object)
        $items+=@{identity=[string]$binding.identity;path=[string]$binding.path;dropped=@($dropped);kept=@($converted.Keys|Sort-Object);changed=[bool]$dropped.Count}
        $minimal+=,$converted
    }
    @{configPath=$path;configHash=(Get-SBFileHash $path);total=$items.Count;changed=@($items|Where-Object {$_.changed}).Count;items=@($items);raw=$raw;bindings=@($minimal)}
}
function Invoke-SBBindingMigration {
    # Preview by default; -Apply rewrites the configuration with a backup of the previous bytes and the previewed hash as precondition.
    # Idempotent: a configuration already in the minimal form is reported as unchanged and left untouched.
    param([string]$BrainRoot,[string]$ConfigPath,[string]$BackupRoot,[switch]$Apply)
    $plan=Get-SBBindingMigrationPlan $BrainRoot $ConfigPath
    $summary=@{schemaVersion=1;configuration=$plan.configPath;total=$plan.total;changed=$plan.changed;applied=$false;state=$(if($plan.changed){'preview'}else{'unchanged'});items=@($plan.items)}
    if(!$Apply -or !$plan.changed){return $summary}
    if(!$BackupRoot){throw (New-SBError 'bindings.config.invalid')}
    $plan.raw.bindings=@($plan.bindings)
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $plan.raw))
    [void](Write-SBFile $plan.configPath $bytes $plan.configHash $BackupRoot)
    $summary.applied=$true;$summary.state='applied';$summary.backupRoot=$BackupRoot
    $summary
}
Export-ModuleMember -Function Get-SBBindingMigrationPlan,Invoke-SBBindingMigration
