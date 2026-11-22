# Test-only functions: used only by test-secondbrain*.ps1 suites (not part of production modules).
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
. (Join-Path $PSScriptRoot 'test-git-environment.ps1')
Assert-SBTestGitEnvironment
# Audit suites set $script:auditLabel and $script:auditChecks before use.
function Assert-Audit($Condition,[string]$Message){if(!$Condition){throw 'FAIL '+$script:auditLabel+': '+$Message};$script:auditChecks++;'PASS '+$script:auditLabel+': '+$Message}
function Get-SBTestRoot {
    $brain=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $root=if($env:SECONDBRAIN_TEST_ROOT){$env:SECONDBRAIN_TEST_ROOT}else{Join-Path $brain '.runtime/tests'}
    $root=Assert-SBCentralDataPath $brain $root
    [IO.Directory]::CreateDirectory($root)|Out-Null
    $root
}
# Minimal Git template for fixture `git init`: only info/exclude (used by rollback-repo), without ~250 sample hooks.
if(!$env:GIT_TEMPLATE_DIR){
    $gitTemplate=Join-Path (Get-SBTestRoot) 'git-template'
    [IO.Directory]::CreateDirectory((Join-Path $gitTemplate 'info'))|Out-Null
    # Parallel suites share this template: rewriting the file in place made a concurrent `git init` or write fail with file-in-use (#795).
    # Create it once, atomically (temp file then move); an existing file with the same text is never touched.
    $excludePath=Join-Path $gitTemplate 'info/exclude'
    if(!([IO.File]::Exists($excludePath) -and [IO.File]::ReadAllText($excludePath) -ceq "# fixture`n")){
        $excludeTemp=$excludePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($excludeTemp,"# fixture`n")
        try{[IO.File]::Move($excludeTemp,$excludePath,$true)}
        catch [IO.IOException]{[IO.File]::Delete($excludeTemp)} # another suite replaced it at the same moment: same content
    }
    $env:GIT_TEMPLATE_DIR=$gitTemplate
}
