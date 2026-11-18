#requires -Version 7.5
<#
.SYNOPSIS
Read-only: proposes the next steps for a project after a task or a run, each with the reason.
.DESCRIPTION
Combines the tracker (tasks in progress, ready and blocked), the last runner run on this workstation (failed processes, unverified acceptance, follow-up tasks
created from findings), the Git and GitHub update preference and whether agent skills are installed. Prints JSON {repository, steps:[{id, kind, priority, title, why, action}]}.
Nothing is written, locked or started: a step names an action (a task to run, a command, an sb command) that you choose explicitly.
Exit: 0 ok, 2 repository not resolved or error.
.EXAMPLE
pwsh -NoProfile -File scripts/next-steps.ps1 -CheckoutPath <project-folder>
#>
[CmdletBinding()]
param([string]$CheckoutPath='.',[ValidateRange(1,20)][int]$Limit=6,[string]$ConfigPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Para.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.RunnerStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Skills.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.NextSteps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Add-SBMessages @{
    'nextsteps.repository' = @{ en = 'Repository not resolved from {0}. Give -CheckoutPath of a managed checkout' }
}
function Invoke-Knowledge([string[]]$Arguments) {
    $configArgs=if($ConfigPath){@('-ConfigPath',$ConfigPath)}else{@()}
    $out=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'knowledge.ps1') @Arguments @configArgs 2>$null|Out-String
    if($LASTEXITCODE -ne 0 -or !$out.Trim()){return @()}
    try{@($out|ConvertFrom-Json)}catch{@()}
}
try{
    $config=Read-SBConfiguration $ConfigPath -ReadOnly
    $full=[IO.Path]::GetFullPath($CheckoutPath)
    $identity=try{Resolve-SBWorkingRepository $full @($config.bindings)}catch{$null}
    if(!$identity){throw (New-SBError 'nextsteps.repository' @($full))}
    $tasks=@(Invoke-Knowledge @('-Tasks','-CheckoutPath',$full))
    # Ready = what the runner itself would accept (autonomous, unblocked), never the wider list of ready tasks that need the owner.
    $ready=@()
    $configArgs=if($ConfigPath){@('-ConfigPath',$ConfigPath)}else{@()}
    $preview=& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-ready-tasks.ps1') -CheckoutPath $full -MaxTasks 0 @configArgs 2>$null|Out-String
    if($LASTEXITCODE -eq 0 -and $preview.Trim()){try{$ready=@(($preview|ConvertFrom-Json).tasks)}catch{$ready=@()}}
    $runs=@((Get-SBRunnerRunList -BrainRoot $config.brainRoot -HostId $config.workstationId -Repository $identity -Limit 1).runs)
    $binding=@($config.bindings|Where-Object {$_.identity -ceq $identity})|Select-Object -First 1
    $record=$null
    $bindingDossier=if($binding){Resolve-SBBindingDossier $config.brainRoot $binding}else{$null}
    if($bindingDossier){
        $recordPath=Join-Path (Resolve-SBParaPath $config.brainRoot ([string]$bindingDossier)) 'repository.json'
        if(Test-Path -LiteralPath $recordPath -PathType Leaf){$record=Read-SBJson $recordPath $null}
    }
    $facts=Get-SBProjectFacts $full
    # The skills card is named by role and resolved through the catalog (id, file and title come from there).
    $skillsCard=$null
    try{$skillsPrompt=(Resolve-SBWorkflowPrompt (Read-SBWorkflowCatalog $config.brainRoot) 'project.skills').prompt;$skillsCard=[ordered]@{id=$skillsPrompt.id;file=$skillsPrompt.file;title='Skills procedure'}}catch{$skillsCard=$null}
    $steps=@(Get-SBNextSteps -SkillsCard $skillsCard -Tasks $tasks -Ready $ready -Runs $runs -GitUpdate (Get-SBGitUpdate $record) -HasSkills:($facts.existingSkills.Count -gt 0) -Limit $Limit)
    ConvertTo-SBJson @{repository=$identity;steps=$steps}
    exit 0
}catch{
    Write-Error $_ -ErrorAction Continue
    exit 2
}
