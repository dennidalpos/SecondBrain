#requires -Version 7.5
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Add-SBMessages @{
    'skills.client.invalid' = @{ en = 'Unknown client: {0}. Supported: claude-code, codex, antigravity' }
    'skills.scope.invalid' = @{ en = 'Scope must be project or user' }
    'skills.checkout.missing' = @{ en = 'Project scope needs an existing checkout folder: {0}' }
    'skills.select.unknown' = @{ en = 'Unknown skill: {0}' }
    'skills.select.required' = @{ en = 'Give -Select with at least one proposed skill name' }
    'skills.home.invalid' = @{ en = 'The home folder must be an existing absolute path: {0}' }
}

# Per-client skill folders, from the official documentation checked on 2026-11-15. liveVerified stays false until a real session shows the skill loaded.
# Observed 2026-11-16 (project scope, synthetic project, headless print mode): Claude Code and Antigravity (agy) listed a skill written by skills.ps1. Codex CLI was not installed, so it stays false; user scope was not observed.
$script:SBSkillClients=[ordered]@{
    'claude-code'=@{label='Claude Code';project='.claude/skills';user='.claude/skills';source='https://code.claude.com/docs/en/skills';checked='2026-11-15';liveVerified=$true}
    'codex'=@{label='Codex';project='.agents/skills';user='.agents/skills';source='https://learn.chatgpt.com/docs/build-skills';checked='2026-11-15';liveVerified=$false}
    'antigravity'=@{label='Antigravity';project='.agents/skills';user='.gemini/config/skills';source='https://antigravity.google/docs/skills';checked='2026-11-15';liveVerified=$true}
}
function Get-SBSkillClients { @($script:SBSkillClients.Keys) }
function Get-SBSkillRoot([string]$Client,[string]$Scope,[string]$CheckoutPath='',[string]$HomeRoot='') {
    if(!$script:SBSkillClients.Contains($Client)){throw (New-SBError 'skills.client.invalid' @($Client))}
    if($Scope -cnotin @('project','user')){throw (New-SBError 'skills.scope.invalid')}
    $entry=$script:SBSkillClients[$Client]
    if($Scope -eq 'project'){
        if(!$CheckoutPath -or !(Test-Path -LiteralPath $CheckoutPath -PathType Container)){throw (New-SBError 'skills.checkout.missing' @($CheckoutPath))}
        return [IO.Path]::GetFullPath((Join-Path $CheckoutPath $entry.project))
    }
    if($HomeRoot){
        if(![IO.Path]::IsPathFullyQualified($HomeRoot) -or !(Test-Path -LiteralPath $HomeRoot -PathType Container)){throw (New-SBError 'skills.home.invalid' @($HomeRoot))}
        return [IO.Path]::GetFullPath((Join-Path $HomeRoot $entry.user))
    }
    # Claude Code honors CLAUDE_CONFIG_DIR for its user folder; the other clients use the profile folder.
    if($Client -eq 'claude-code' -and $env:CLAUDE_CONFIG_DIR){return [IO.Path]::GetFullPath((Join-Path $env:CLAUDE_CONFIG_DIR 'skills'))}
    [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('UserProfile')) $entry.user))
}
function Get-SBSkillClientInfo { $script:SBSkillClients.Keys|ForEach-Object {[ordered]@{client=$_;label=$script:SBSkillClients[$_].label;projectFolder=$script:SBSkillClients[$_].project;userFolder=$script:SBSkillClients[$_].user;source=$script:SBSkillClients[$_].source;checked=$script:SBSkillClients[$_].checked;liveVerified=$script:SBSkillClients[$_].liveVerified}} }

function Get-SBProjectFacts([string]$CheckoutPath) {
    # Read-only facts from manifests and top-level layout; no file content beyond manifests and AGENTS.md headings is read.
    $root=[IO.Path]::GetFullPath($CheckoutPath)
    $has={param($n) Test-Path -LiteralPath (Join-Path $root $n)}
    $checks=[Collections.Generic.List[string]]::new()
    $stacks=[Collections.Generic.List[string]]::new()
    if(& $has 'package.json'){
        $stacks.Add('node')
        try{$pkg=Get-Content -LiteralPath (Join-Path $root 'package.json') -Raw|ConvertFrom-Json;foreach($name in @('check','lint','test','build')){if($pkg.PSObject.Properties['scripts'] -and $pkg.scripts.PSObject.Properties[$name]){$checks.Add('npm run '+$name)}}}catch{[void]$_}
    }
    if(& $has 'Cargo.toml'){$stacks.Add('rust');$checks.Add('cargo test')}
    if((& $has 'pyproject.toml') -or (& $has 'requirements.txt')){$stacks.Add('python');$checks.Add('python -m pytest')}
    if(@(Get-ChildItem -LiteralPath $root -Filter '*.sln' -File -ErrorAction SilentlyContinue).Count -or @(Get-ChildItem -LiteralPath $root -Filter '*.csproj' -File -ErrorAction SilentlyContinue).Count){$stacks.Add('dotnet');$checks.Add('dotnet test')}
    if(@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue|Select-Object -First 1).Count){$stacks.Add('powershell')}
    if(& $has 'go.mod'){$stacks.Add('go');$checks.Add('go test ./...')}
    $dirs=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -notin @('.git','node_modules','target','.runtime','dist','build','bin','obj','.claude','.agents','.gemini')-and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object Name|Select-Object -First 20|ForEach-Object Name)
    $existing=@();foreach($rel in @('.claude/skills','.agents/skills')){$p=Join-Path $root $rel;if(Test-Path -LiteralPath $p -PathType Container){$existing+=@(Get-ChildItem -LiteralPath $p -Directory|ForEach-Object {$rel+'/'+$_.Name})}}
    [ordered]@{
        checkout=$root;stacks=@($stacks|Sort-Object -Unique);checks=@($checks);folders=$dirs
        hasChangelog=(& $has 'CHANGELOG.md');hasWorkflows=(& $has '.github/workflows');hasAgentsFile=((& $has 'AGENTS.md') -or (& $has 'CLAUDE.md'))
        hasDocs=(& $has 'docs');existingSkills=@($existing)
    }
}
function ConvertTo-SBSkillText([string]$Name,[string]$Description,[string]$Body) {
    "---`nname: $Name`ndescription: $Description`n---`n`n$($Body.Trim())`n"
}
function Get-SBSkillProposals($Facts) {
    # Proposals come from detected facts only: each one states why it was proposed and which fact supports it.
    $list=@()
    if($Facts.checks.Count){
        $commands=($Facts.checks|ForEach-Object {'- `'+$_+'`'}) -join "`n"
        $body="# Run the project checks`n`nBefore you report a change as done, run the checks that fit what you touched and report their real output.`n`nDetected commands (confirm them against the project's own instructions before relying on them):`n$commands`n`n- Run the narrowest check first, then the wider ones.`n- If a check fails, show the failure; do not claim success.`n- Say which checks you did not run."
        $list+=[ordered]@{name='project-checks';reason='Detected check commands: '+($Facts.checks -join ', ');description='Runs the right project checks before work is reported as done. Use when finishing a code change or when asked to verify, test or lint the project.';body=$body}
    }
    if($Facts.folders.Count){
        $folders=($Facts.folders|ForEach-Object {'- `'+$_+'/`'}) -join "`n"
        $body="# Repository map`n`nUse this map to find where things live before searching broadly.`n`nTop-level folders (detected, may be incomplete):`n$folders`n`n- Read the folder's own README or instructions before editing inside it.`n- Prefer existing patterns in the neighbouring files over new ones.`n- Update this skill when the layout changes."
        $list+=[ordered]@{name='repo-map';reason='Top-level layout: '+(($Facts.folders|Select-Object -First 6) -join ', ');description='Orients the agent in the repository layout. Use at the start of a task, or when unsure where code, tests or documentation live.';body=$body}
    }
    if($Facts.hasChangelog){
        $list+=[ordered]@{name='changelog-entry';reason='CHANGELOG.md present';description='Writes a changelog entry in the project style. Use when a change is user-visible or a release is prepared.';body="# Changelog entry`n`n1. Read the top of CHANGELOG.md and copy its structure, tense and level of detail.`n2. Add one entry per user-visible change, under the unreleased heading if there is one.`n3. Do not change the version or tag a release unless asked.`n4. Keep internal refactors out unless they change behavior."}
    }
    if($Facts.hasWorkflows){
        $list+=[ordered]@{name='ci-failure-triage';reason='.github/workflows present';description='Triages a failing CI run from its logs. Use when a pull request or push shows failing checks.';body="# CI failure triage`n`n1. List the failing jobs and open the first failing step's log.`n2. Separate the root failure from the follow-on errors.`n3. Reproduce locally with the same command when possible.`n4. Report the cause, the minimal fix and anything you could not verify.`n5. Do not re-run or disable checks to make them pass."}
    }
    $list+=[ordered]@{name='review-checklist';reason='Applies to any repository with code changes';description='Reviews a diff against a short checklist. Use when asked to review a change, a branch or a pull request.';body="# Review checklist`n`n- Correctness: does the diff do what the request says, including edge cases and error paths?`n- Scope: does it change anything the request did not ask for?`n- Tests: is new behavior covered, and were the relevant checks run?`n- Safety: secrets, paths, input from outside the program, destructive operations.`n- Report findings ordered by severity, each with the file and line, and say what you did not check."}
    if($Facts.hasAgentsFile){
        $list+=[ordered]@{name='secondbrain-context';reason='AGENTS.md or CLAUDE.md present: project instructions exist';description='Loads the project context from SecondBrain before work. Use at the start of a session in a repository managed by SecondBrain.';body="# Load the project context`n`n1. Load the slim startup context with the SecondBrain MCP tool get_startup_context or `scripts/knowledge.ps1 -Startup` from the SecondBrain checkout.`n2. Read the repository instructions (AGENTS.md) and follow their checks.`n3. Ask before any commit, push or publication; record the outcome where the project tracks its work."}
    }
    foreach($p in $list){$p.content=ConvertTo-SBSkillText $p.name $p.description $p.body;$p.Remove('body')}
    @($list)
}
function Get-SBPromptSkillProposal([string]$BrainRoot,[string]$Code) {
    # #500: a proven catalog card exported as a skill: name sb-<code>, the summary as description, the card body (role, context, task, format) as the skill body.
    $catalog=Read-SBWorkflowCatalog $BrainRoot
    $prompt=(Resolve-SBWorkflowPrompt $catalog $Code).prompt
    $card=Read-SBWorkflowPrompt $BrainRoot $prompt $catalog
    $summary=([string](Get-SBWorkflowField $prompt 'summary')).TrimEnd('.').Replace(': ',' - ')
    $name='sb-'+([string]$prompt.code).ToLowerInvariant()
    $description=$summary+'. SecondBrain prompt card '+$prompt.code+': use it when the user asks for this task.'
    $lines=@($card -split "`n")
    [ordered]@{name=$name;reason='Prompt card '+$prompt.code+' of the SecondBrain catalog';description=$description
        content=(ConvertTo-SBSkillText $name $description ("# "+$summary+"`n`n"+(($lines|Select-Object -Skip 1) -join "`n")))}
}
function New-SBSkillInstallPlan($Proposals,[string[]]$Select,[string[]]$Clients,[string]$Scope,[string]$CheckoutPath='',[string]$HomeRoot='') {
    if(!@($Select).Count){throw (New-SBError 'skills.select.required')}
    $chosen=@();foreach($name in @($Select)){$m=@($Proposals|Where-Object {$_.name -ceq $name});if($m.Count -ne 1){throw (New-SBError 'skills.select.unknown' @($name))};$chosen+=$m[0]}
    $items=@()
    foreach($client in @($Clients)){
        $root=Get-SBSkillRoot $client $Scope $CheckoutPath $HomeRoot
        foreach($skill in $chosen){
            $file=Join-Path (Join-Path $root $skill.name) 'SKILL.md'
            $bytes=[Text.Encoding]::UTF8.GetBytes($skill.content)
            $current=Get-SBFileHash $file
            $state=if($current -eq 'absent'){'new'}elseif($current -ceq (Get-SBHash $bytes)){'unchanged'}else{'conflict'}
            # Clients that share a folder (codex and antigravity: .agents/skills) write that file once.
            if(@($items|Where-Object {$_.file -ceq $file}).Count){$state='shared'}
            $items+=[ordered]@{client=$client;scope=$Scope;skill=$skill.name;file=$file;state=$state;expected=$current;bytes=$bytes}
        }
    }
    @($items)
}
Export-ModuleMember -Function Get-SBSkillClients,Get-SBSkillRoot,Get-SBSkillClientInfo,Get-SBProjectFacts,Get-SBSkillProposals,Get-SBPromptSkillProposal,New-SBSkillInstallPlan
