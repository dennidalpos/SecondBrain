#requires -Version 7.5
# Next steps after a task or run (#659): reasoned, ordered proposals from facts only. Pure checks, synthetic data.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.NextSteps.psm1') -Force
$script:nsChecks=0
function Assert-Ns($Condition,[string]$Message){if(!$Condition){throw ('FAIL NEXTSTEPS: '+$Message)};$script:nsChecks++}
function Ids($steps){@($steps|ForEach-Object id) -join ','}
$git=@{mode='commit-push-main';branch='main';confirmed=$false}
$confirmed=@{mode='none';branch='main';confirmed=$true}

# Nothing to report: only housekeeping, each with a reason.
$steps=@(Get-SBNextSteps -Tasks @() -Ready @() -Runs @() -GitUpdate $git -HasSkills $false -SkillsCard ([ordered]@{id='pmt-3d7b91c4';file='SYS18.md';title='Skills procedure'}))
Assert-Ns ((Ids $steps) -ceq 'git-update,skills') ('housekeeping only: '+(Ids $steps))
Assert-Ns (@($steps|Where-Object {!$_.why -or !$_.title -or !$_.action.value}).Count -eq 0) 'every step has title, reason and action'
Assert-Ns (@(Get-SBNextSteps -Tasks @() -Ready @() -Runs @() -GitUpdate $confirmed -HasSkills $true).Count -eq 0) 'confirmed preference and skills installed: nothing to propose'

# Order follows urgency: verify what ran, finish what is open, new work, housekeeping.
$tasks=@(@{id='T-2';seq=2;status='in_progress';title='two';priority='P2'},@{id='T-1';seq=1;status='in_progress';title='one';priority='P2'},@{id='T-3';seq=3;status='todo';title='three';priority='P1'})
$ready=@(@{id='T-4';seq=4;priority='P2';title='#4 - four'},@{id='T-5';seq=5;priority='P1';title='#5 - five'})
$run=@{results=@(@{id='T-1';process='failed'},@{id='T-2';process='succeeded';acceptance='unverified'},@{id='T-6';process='succeeded';acceptance='verified';findings=@{created=2}})}
$steps=@(Get-SBNextSteps -Tasks $tasks -Ready $ready -Runs @($run) -GitUpdate $git -HasSkills $false -Limit 20 -SkillsCard ([ordered]@{id='pmt-3d7b91c4';file='SYS18.md';title='Skills procedure'}))
Assert-Ns ((Ids $steps) -ceq 'recheck-failed,verify-acceptance,review-findings,finish-open,run-next,git-update,skills') ('full order: '+(Ids $steps))
$open=$steps|Where-Object id -eq 'finish-open'
Assert-Ns ($open.action.value -ceq 'T-1' -and $open.title -match '#1') 'in-progress tasks start with the lowest number'
$next=$steps|Where-Object id -eq 'run-next'
Assert-Ns ($next.action.value -ceq 'T-5' -and $next.title -notmatch '#5 - ' -and $next.why -match '2 ready') 'next ready task is the highest priority, title without the number prefix'
Assert-Ns ((@(Get-SBNextSteps -Tasks $tasks -Ready $ready -Runs @($run) -GitUpdate $git -HasSkills $false -Limit 3)).Count -eq 3) 'limit applies'

# Verified results with no findings add no review step; blocked tasks without ready ones ask for a decision.
$clean=@{results=@(@{id='T-1';process='succeeded';acceptance='verified'})}
Assert-Ns ((Ids (Get-SBNextSteps -Tasks @() -Ready @() -Runs @($clean) -GitUpdate $confirmed -HasSkills $true)) -ceq '') 'a clean run proposes nothing to verify'
$blocked=@(@{id='B-1';seq=9;status='blocked';title='b';priority='P2'})
Assert-Ns ((Ids (Get-SBNextSteps -Tasks $blocked -Ready @() -Runs @() -GitUpdate $confirmed -HasSkills $true)) -ceq 'unblock') 'blocked without ready proposes to decide'
Assert-Ns ((Ids (Get-SBNextSteps -Tasks $blocked -Ready $ready -Runs @() -GitUpdate $confirmed -HasSkills $true)) -ceq 'run-next') 'ready work wins over the unblock step'
# Follow-up proposals and the card (#672): data only, the window writes through the task tool after a preview and a confirmation.
$ver=$steps|Where-Object id -eq 'verify-acceptance'
Assert-Ns ($ver.followUp.title -and $ver.followUp.description -and @($ver.followUp.acceptance).Count -ge 1 -and $ver.followUp.priority -cmatch '^P[0-3]$') 'verify step carries a complete follow-up task'
Assert-Ns (@(@($ver.followUp.acceptance)|Where-Object {$_ -match ';'}).Count -eq 0) 'criteria hold no semicolon'
Assert-Ns ((@($steps|Where-Object id -eq 'skills')[0]).card.file -ceq 'SYS18.md') 'skills step names its card'
'SUCCESS NEXTSTEPS: '+$script:nsChecks+' checks'
