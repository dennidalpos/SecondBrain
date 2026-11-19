#requires -Version 7.5
# sb resync (#726): plan from synthetic findings (drifted block, diverged tracker, moved checkout) and the no-write-without-apply rule.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Resync.psm1') -Force
$script:rsChecks=0
function Assert-Rs($Condition,[string]$Message){if(!$Condition){throw ('FAIL RESYNC: '+$Message)};$script:rsChecks++}
$id='github.com/test/resync'
$aligned=Get-SBResyncPlan -Findings @() -Repository $id
Assert-Rs ($aligned.status -ceq 'aligned' -and $aligned.items.Count -eq 0) 'no findings: aligned'
$drift=Get-SBResyncPlan -Findings @(@{kind='directive-pending';repository=$id}) -Repository $id
Assert-Rs ($drift.status -ceq 'safe-to-apply' -and $drift.safeCount -eq 1 -and $drift.items[0].action -match 'sb sync') 'drifted block: safe, names sb sync'
$edited=Get-SBResyncPlan -Findings @(@{kind='directive-conflict';repository=$id}) -Repository $id
Assert-Rs ($edited.status -ceq 'needs-decision' -and $edited.items[0].action -match 'repository file' -and $edited.items[0].action -match 'outside the block' -and $edited.items[0].action -match 'sb sync') 'hand-edited block: conflict, names the move outside the block and sb sync'
$tracker=Get-SBResyncPlan -Findings @(@{kind='tracker-merge';detail='Tracker merge pending for x'}) -Repository $id
Assert-Rs ($tracker.status -ceq 'needs-decision' -and $tracker.items[0].action -match 'import-tracker.ps1 -Merge' -and $tracker.items[0].detail -match 'pending') 'diverged tracker: conflict, names import-tracker -Merge'
$moved=Get-SBResyncPlan -Findings @(@{kind='repository-unverified';reason='checkout moved'}) -Repository $id
Assert-Rs ($moved.status -ceq 'needs-decision' -and $moved.items[0].action -match 'sb onboard' -and $moved.items[0].action -match 'sb offboard') 'moved checkout: conflict, names sb offboard and sb onboard'
$memory=Get-SBResyncPlan -Findings @(@{kind='closure-memory-pending'}) -Repository $id
Assert-Rs ($memory.items[0].prompt -ceq 'session.close') 'a finding fixed by a prompt names the prompt role'
$unknown=Get-SBResyncPlan -Findings @(@{kind='something-new'}) -Repository $id
Assert-Rs ($unknown.status -ceq 'needs-decision' -and $unknown.items[0].action -match 'Unrecognized') 'unknown finding is never treated as safe'
$mixed=Get-SBResyncPlan -Findings @(@{kind='directive-pending'},@{kind='tracker-merge'}) -Repository $id
Assert-Rs ($mixed.safeCount -eq 1 -and $mixed.manualCount -eq 1 -and $mixed.status -ceq 'needs-decision') 'mixed findings: counted apart'
$script=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'resync.ps1'))
$body=$script.Substring($script.IndexOf('param('));$beforeApply=$body.Substring(0,$body.IndexOf('if($Apply'))
Assert-Rs ($beforeApply -notmatch '-Sync' -and $script -match 'if\(\$Apply -and \$plan\.safeCount\)\{\s*\$arguments=@\(''-Sync''') 'resync runs -Sync only under -Apply'
'SUCCESS RESYNC: '+$script:rsChecks+' checks'
