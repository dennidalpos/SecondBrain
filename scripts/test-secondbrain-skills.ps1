#requires -Version 7.5
# Fixtures for sb skills (#658): read-only analysis, proposals from facts, per-client folders, preview, conflicts, apply with backup. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Skills.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:skChecks=0
function Assert-Sk($Condition,[string]$Message){if(!$Condition){throw ('FAIL SKILLS: '+$Message)};$script:skChecks++}
$root=Join-Path (Get-SBTestRoot) ('skills-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain'
function Put([string]$base,[string]$rel,[string]$text){$p=Join-Path $base $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text)}
try{
    $project=Join-Path $root 'project';$homeDir=Join-Path $root 'home';[IO.Directory]::CreateDirectory($homeDir)|Out-Null
    Put $project 'package.json' '{"name":"x","scripts":{"test":"echo t","lint":"echo l","start":"echo s"}}'
    Put $project 'CHANGELOG.md' "# Changelog`n"
    Put $project 'src/index.js' 'x'
    Put $project '.github/workflows/ci.yml' 'name: ci'
    Put $project 'AGENTS.md' '# Agents'

    # Folders per client, from the official documentation.
    Assert-Sk ((Get-SBSkillRoot 'claude-code' 'project' $project) -ceq (Join-Path $project '.claude/skills' | ForEach-Object {[IO.Path]::GetFullPath($_)})) 'claude-code project folder'
    Assert-Sk ((Get-SBSkillRoot 'codex' 'project' $project) -ceq [IO.Path]::GetFullPath((Join-Path $project '.agents/skills'))) 'codex project folder'
    Assert-Sk ((Get-SBSkillRoot 'antigravity' 'user' '' $homeDir) -ceq [IO.Path]::GetFullPath((Join-Path $homeDir '.gemini/config/skills'))) 'antigravity user folder'
    Assert-Sk ((Get-SBSkillRoot 'codex' 'user' '' $homeDir) -ceq [IO.Path]::GetFullPath((Join-Path $homeDir '.agents/skills'))) 'codex user folder'
    $threw=$false;try{Get-SBSkillRoot 'unknown' 'project' $project}catch{$threw=$true};Assert-Sk $threw 'unknown client refused'
    Assert-Sk ((@(Get-SBSkillClientInfo|Where-Object liveVerified|ForEach-Object client)|Sort-Object) -join ',') -ceq 'antigravity,claude-code' 'only clients observed listing a skill are live-verified (codex not observed)'

    # Facts and proposals come from detected facts only.
    $facts=Get-SBProjectFacts $project
    Assert-Sk (($facts.checks -contains 'npm run test') -and ($facts.checks -contains 'npm run lint') -and !($facts.checks -contains 'npm run start')) 'checks detected from package.json'
    $proposals=@(Get-SBSkillProposals $facts)
    $names=@($proposals|ForEach-Object name)
    Assert-Sk (('project-checks','changelog-entry','ci-failure-triage','review-checklist','secondbrain-context','repo-map'|Where-Object {$_ -notin $names}).Count -eq 0) ('expected proposals: '+($names -join ','))
    $bare=Join-Path $root 'bare';[IO.Directory]::CreateDirectory($bare)|Out-Null
    $bareNames=@(Get-SBSkillProposals (Get-SBProjectFacts $bare)|ForEach-Object name)
    Assert-Sk ($bareNames -ceq 'review-checklist') ('an empty project gets only the generic skill: '+($bareNames -join ','))
    Assert-Sk (($proposals|Where-Object name -eq 'project-checks').content -match '(?s)^---\nname: project-checks\ndescription: .+\n---\n') 'SKILL.md has name and description frontmatter'

    # CLI: analyze is read-only; install previews, then applies with a backup.
    foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
    Put $brain 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
    $runtime=Get-SBLocalRoot $brain 'fixture';$cfg=Join-Path $runtime 'workstation.json'
    Put $brain ([IO.Path]::GetRelativePath($brain,$cfg)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=$runtime;backupRoot=(Join-Path $runtime 'backups');ides=@();bindings=@()})
    $cli=Join-Path $brain 'scripts/skills.ps1'
    function Invoke-Sk([string[]]$Arguments){$out=& pwsh -NoProfile -File $cli -ConfigPath $cfg @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}
    $before=@(Get-ChildItem -LiteralPath $project -Recurse -File -Force|ForEach-Object FullName).Count
    $r=Invoke-Sk @('-Analyze','-CheckoutPath',$project)
    Assert-Sk ($r.code -eq 0 -and $r.out -match 'project-checks' -and $r.out -match 'code.claude.com') ('analyze lists proposals and sources: '+$r.out)
    Assert-Sk (@(Get-ChildItem -LiteralPath $project -Recurse -File -Force).Count -eq $before) 'analyze writes nothing'
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','project-checks,repo-map','-Client','claude-code,codex','-Scope','project')
    Assert-Sk ($r.code -eq 0 -and $r.out -match '"apply":\s*false' -and $r.out -match '"state":\s*"new"' -and @(Get-ChildItem -LiteralPath $project -Recurse -File -Force).Count -eq $before) ('preview writes nothing: '+$r.out)
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','nonexistent','-Client','codex','-Scope','project')
    Assert-Sk ($r.code -ne 0) 'unknown skill refused'
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','project-checks,repo-map','-Client','claude-code,codex','-Scope','project','-Apply')
    Assert-Sk ($r.code -eq 0) ('apply succeeds: '+$r.out)
    foreach($rel in @('.claude/skills/project-checks/SKILL.md','.claude/skills/repo-map/SKILL.md','.agents/skills/project-checks/SKILL.md','.agents/skills/repo-map/SKILL.md')){Assert-Sk (Test-Path -LiteralPath (Join-Path $project $rel) -PathType Leaf) "written: $rel"}
    Assert-Sk (!(Test-Path -LiteralPath (Join-Path $project '.gemini'))) 'no folder for a client that was not selected'

    # A second apply is a no-op; a modified file is a conflict, skipped unless -Overwrite.
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','repo-map','-Client','codex','-Scope','project','-Apply')
    Assert-Sk ($r.code -eq 0 -and $r.out -match '"written":\s*\[\s*\]') 'unchanged skill is not rewritten'
    $edited=Join-Path $project '.agents/skills/repo-map/SKILL.md';[IO.File]::WriteAllText($edited,'edited by the user')
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','repo-map','-Client','codex','-Scope','project','-Apply')
    Assert-Sk ($r.code -eq 1 -and $r.out -match 'skippedConflicts' -and [IO.File]::ReadAllText($edited) -ceq 'edited by the user') 'conflict is skipped and the user file is kept'
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','repo-map','-Client','codex','-Scope','project','-Apply','-Overwrite')
    Assert-Sk ($r.code -eq 0 -and [IO.File]::ReadAllText($edited) -match '^---\nname: repo-map') 'overwrite replaces the file'
    Assert-Sk (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'backups') -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0) 'overwrite kept a backup'

    # User scope goes under the given home folder only.
    $r=Invoke-Sk @('-Install','-CheckoutPath',$project,'-Select','review-checklist','-Client','antigravity','-Scope','user','-HomeRoot',$homeDir,'-Apply')
    Assert-Sk ($r.code -eq 0 -and (Test-Path -LiteralPath (Join-Path $homeDir '.gemini/config/skills/review-checklist/SKILL.md'))) ('user scope written under the home folder: '+$r.out)
    'SUCCESS SKILLS: '+$script:skChecks+' checks'
}finally{
    $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath((Get-SBTestRoot)).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(!$full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Skills fixture outside the test perimeter'}
    if($env:SECONDBRAIN_TEST_KEEP -ne '1' -and (Test-Path -LiteralPath $full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
