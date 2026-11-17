#requires -Version 7.5
# One-shot read-only analyses with an agent CLI (desktop orchestrator): repository directive proposals (analysis.directives) and task autonomy
# analysis (analysis.task). The agent reads the checkout with read-only tools and answers one JSON object validated against a schema in
# config/analysis/; for tasks the object carries tool calls (ask_user, propose_task_update, mark_not_automatable) that the orchestrator
# dispatches as multiple-choice questions and a reviewed tracker update. Nothing here writes to the dossier or the checkout: the output
# goes to the work folder the caller names, and tracker writes go through knowledge.ps1 in scripts/agents.ps1.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAdapters.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.RunnerStatus.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Add-SBMessages @{
    'analysis.agent.notready' = @{ en = '{0} is not ready ({1}): install or update the CLI, then probe the agents again' }
    'analysis.quota.exhausted' = @{ en = '{0} quota exhausted until {1}: analysis not started. Pick another agent or retry after the reset' }
    'analysis.limit' = @{ en = '{0} limit during the analysis ({1}): {2}' }
    'analysis.agent.failed' = @{ en = 'Analysis failed with {0} ({1}, exit {2}): {3}' }
    'analysis.output.invalid' = @{ en = '{0} answer does not match the schema after {1} attempts: {2}. Retry or pick a more capable model' }
    'analysis.card.missing' = @{ en = 'Prompt card {0} not found in direttive/prompts' }
}
$script:SBAnalysisKinds=@{directives=@{card='analysis.directives';schema='directives.schema.json'};task=@{card='analysis.task';schema='task.schema.json'}}
function Get-SBAnalysisSchemaPath([string]$BrainRoot,[ValidateSet('directives','task')][string]$Kind) {
    Join-Path $BrainRoot ('config/analysis/'+$script:SBAnalysisKinds[$Kind].schema)
}
function Get-SBLightModel([string]$BrainRoot,[string]$Provider) {
    # Default light model of one-shot analyses: roles.light.<provider> of config/agent-models.json, replaced by the workstation override.
    $role=@{model=$null;effort=$null;source='none'}
    foreach($path in @((Join-Path $BrainRoot 'config/agent-models.json'),(Join-Path $BrainRoot ('.runtime/hosts/'+(Get-SBHostId)+'/agent-models.local.json')))){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try{$data=Read-SBText $path|ConvertFrom-Json -AsHashtable}catch{continue}
        if($data -isnot [hashtable] -or $data['roles'] -isnot [hashtable] -or $data.roles['light'] -isnot [hashtable] -or $data.roles.light[$Provider] -isnot [hashtable]){continue}
        $entry=$data.roles.light[$Provider]
        $role=@{model=$(if($entry['model']){[string]$entry.model}else{$null});effort=$(if($entry['effort']){[string]$entry.effort}else{$null});source=[IO.Path]::GetFileName($path)}
    }
    $role
}
# The card is named by role or ID and resolved through the catalog; its file name is never written in code.
function Get-SBPromptCardText([string]$BrainRoot,[string]$Key) {
    $Code=$Key
    try{$Code=(Resolve-SBWorkflowPrompt (Read-SBWorkflowCatalog $BrainRoot) $Key).prompt.code}catch{throw (New-SBError 'analysis.card.missing' @($Key))}
    $path=Join-Path $BrainRoot ('direttive/prompts/'+$Code+'.md')
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'analysis.card.missing' @($Code))}
    (Read-SBText $path).Trim()
}
function Get-SBAnalysisLanguageName([string]$Language) { if($Language -eq 'en'){'English'}else{'Italian'} }
function Limit-SBAnalysisText([string]$Text,[int]$Max) {
    if(!$Text){return ''}
    if($Text.Length -le $Max){return $Text}
    $Text.Substring(0,$Max)+"`n[... truncated: $($Text.Length-$Max) more characters]"
}
function New-SBDirectivesAnalysisPrompt {
    # Prompt of the directive proposal: the analysis.directives card, the blocks already loaded in every session (global, common, current dossier text,
    # AGENTS.md outside the managed blocks) and the character budget. The agent reads the checkout itself with read-only tools.
    param([string]$BrainRoot,[string]$Identity,[string]$GlobalText,[string]$CommonText,[string]$DossierText,[string]$AgentsOutside,[int]$Budget=25000,[int]$UsedCharacters=0,[string]$Language='it')
    $lang=Get-SBAnalysisLanguageName $Language
    @(
        (Get-SBPromptCardText $BrainRoot 'analysis.directives'),
        '',
        '# Task for this session',
        "Repository: $Identity. The current directory is its checkout: survey it with your read-only tools (manifests, build and test scripts, CI workflows, folder structure, existing guides), then propose the repository-specific directives.",
        "Write titles, bodies and rationales in $lang. Bodies are Markdown, without HTML comments, without absolute paths and without template placeholders in double braces.",
        "Character budget: every session loads about $UsedCharacters of $Budget characters already; keep the proposal short (aim for 1,500 to 3,000 characters in total).",
        '',
        '## Global directives (already loaded in every session, do not repeat)',
        (Limit-SBAnalysisText $GlobalText 9000),
        '',
        '## Common repository block (already loaded, do not repeat)',
        (Limit-SBAnalysisText $CommonText 4000),
        '',
        '## Current repository-specific directives in the dossier (improve or replace)',
        $(if($DossierText){Limit-SBAnalysisText $DossierText 6000}else{'(none yet)'}),
        '',
        '## AGENTS.md of the checkout outside the managed blocks (already loaded, do not repeat)',
        $(if($AgentsOutside){Limit-SBAnalysisText $AgentsOutside 6000}else{'(empty)'})
    ) -join "`n"
}
function New-SBTaskAnalysisPrompt {
    # Prompt of the task autonomy analysis: the analysis.task card, the task as the tracker holds it, why the runner does not take it now,
    # the state of its dependencies and the answers already given in earlier rounds.
    param([string]$BrainRoot,$Task,[string]$Reason,$Dependencies=@(),$Rounds=@(),[string]$Language='it',[int]$Round=1,[int]$MaxRounds=3)
    $lang=Get-SBAnalysisLanguageName $Language
    $answered=@()
    foreach($r in @($Rounds)){foreach($a in @($r['answers'])){if($a){$answered+=,$a}}}
    @(
        (Get-SBPromptCardText $BrainRoot 'analysis.task'),
        '',
        '# Task for this session',
        "Analyze only task $($Task['id']) of this repository. The current directory is its checkout: read code and files with your read-only tools when the decision depends on them.",
        "Write summary, questions, options and the proposed update in $lang. Round $Round of at most $MaxRounds$(if($Round -ge $MaxRounds){': this is the last round, do not ask further questions'}).",
        "Why the runner does not take it now: $(if($Reason){$Reason}else{'runnable already'}).",
        'The runner takes a task only when status is todo, execution is autonomous, its stream is not qualifica-finale, intervento-su-richiesta or coordinamento-prodotti, awaiting is empty or structural-completion, every dependency is done, and requires does not name computer-use.',
        '',
        '## Task (tracker JSON)',
        (ConvertTo-SBJson $Task),
        '',
        '## Dependencies and their status',
        $(if(@($Dependencies).Count){(@($Dependencies)|ForEach-Object {"- $($_.id): $($_.status)"}) -join "`n"}else{'(none)'}),
        '',
        '## Answers of the owner so far',
        $(if($answered.Count){ConvertTo-SBJson $answered}else{'(none yet)'})
    ) -join "`n"
}
function Invoke-SBAgentOneShot {
    # One read-only analysis: quota read now, the installed CLI with the ReadOnly profile in the checkout, the answer extracted from the
    # CLI envelope and validated against the schema; one retry with the validation errors when it does not match. No model or effort
    # given: the light role of config/agent-models.json. Files in -OutputFolder: prompt.txt, agent-output-<n>.jsonl, agent-error-<n>.txt, result.json.
    param([Parameter(Mandatory)][string]$Provider,[string]$Model,[string]$Effort,[Parameter(Mandatory)][string]$Prompt,[Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CheckoutPath,[string]$OutputFolder,[string]$BrainRoot,[string]$HostId,[int]$TimeoutSeconds=600,[string]$AgentPath,
        [switch]$AllowCustomModel,$Capabilities,[int]$MaxAttempts=2)
    if(!$BrainRoot){$BrainRoot=(Get-SBBrainRootPath)}
    if(!$HostId){$HostId=Get-SBHostId}
    $info=Get-SBAgentProvider $Provider
    $caps=if($Capabilities){$Capabilities}else{Get-SBAgentCapabilities -Provider $Provider -BrainRoot $BrainRoot -AgentPath $AgentPath}
    if($caps.status -ne 'ready'){throw (New-SBError 'analysis.agent.notready' @($info.name,$caps.status))}
    $role='explicit'
    if(!$Model -and !$Effort){
        $light=Get-SBLightModel $BrainRoot $Provider
        $Model=if($light.model -and $caps.supports.model){$light.model}else{$null}
        $Effort=if($light.effort -and $caps.supports.effort){$light.effort}else{$null}
        $role='light'
    }
    [void](Test-SBAgentSelection $caps $Model $Effort -AllowCustomModel:($AllowCustomModel -or $role -eq 'light'))
    $observation=Get-SBRunnerQuotaObservation $BrainRoot $HostId $Provider
    $quota=Get-SBAgentQuota -Provider $Provider -Observation $observation
    if($quota.state -eq 'exhausted'){throw (New-SBError 'analysis.quota.exhausted' @($info.name,$quota.resetAt))}
    $exe=Resolve-SBAgentExecutable $(if($AgentPath){$AgentPath}else{$info.command})
    if(!$exe){throw (New-SBError 'analysis.agent.notready' @($info.name,'not-found'))}
    $shim=[bool]([string]$exe.path -match '\.(cmd|bat)$')
    $invocation=New-SBAgentInvocation -Provider $Provider -Capabilities $caps -Model $Model -Effort $Effort -Profile ReadOnly -SchemaPath $SchemaPath -NoInlineSchema:$shim
    $schemaText=Read-SBText $SchemaPath
    $instructions=@(
        '',
        '# Output',
        'Answer with exactly one JSON object and nothing else (no prose, no code fence). It must validate against this JSON Schema; use null for fields that do not apply to a call:',
        $schemaText.Trim()
    ) -join "`n"
    $basePrompt=$Prompt.TrimEnd()+"`n"+$instructions
    $utf8=[Text.UTF8Encoding]::new($false)
    if($OutputFolder){[IO.Directory]::CreateDirectory($OutputFolder)|Out-Null;[IO.File]::WriteAllText((Join-Path $OutputFolder 'prompt.txt'),$basePrompt,$utf8)}
    $attempt=0;$current=$basePrompt;$check=$null;$parsed=$null;$seconds=0
    while($attempt -lt $MaxAttempts){
        $attempt++
        $log=if($OutputFolder){Join-Path $OutputFolder "agent-output-$attempt.jsonl"}else{$null}
        $run=Invoke-SBAgentProcess -Executable $exe -Arguments $invocation.arguments -Prompt $current -WorkingDirectory $CheckoutPath -TimeoutSeconds $TimeoutSeconds -OutputLog $log -TickSeconds 0
        $seconds+=$run.seconds
        if($OutputFolder){[IO.File]::WriteAllText((Join-Path $OutputFolder "agent-error-$attempt.txt"),$run.error,$utf8)}
        $limit=if($run.state -ne 'timeout'){Get-SBAgentLimitState -Provider $Provider -Output $run.output -ErrorOutput $run.error -ExitCode $run.exitCode}else{$null}
        if($limit){throw (New-SBError 'analysis.limit' @($info.name,$limit.state,$limit.message))}
        if($run.state -ne 'finished' -or $run.exitCode -ne 0){
            $tail=((@([string]$run.error -split "`r?`n")|Where-Object {$_.Trim()}|Select-Object -Last 6) -join ' ').Trim()
            throw (New-SBError 'analysis.agent.failed' @($info.name,$run.state,$run.exitCode,$(if($tail){$tail}else{'-'})))
        }
        $parsed=ConvertFrom-SBAgentStructuredOutput -Provider $Provider -Output $run.output
        $check=Test-SBAgentStructuredOutput $parsed.json $schemaText
        if($check.valid){break}
        $current=$basePrompt+"`n`n# Correction`nYour previous answer did not validate: "+(($check.errors) -join '; ')+". Reply again with only the corrected JSON object."
    }
    if(!$check.valid){throw (New-SBError 'analysis.output.invalid' @($info.name,$attempt,(($check.errors) -join '; ')))}
    $result=$parsed.json|ConvertFrom-Json -AsHashtable -Depth 40
    $outcome=[ordered]@{provider=$Provider;model=$Model;effort=$Effort;role=$role;nativeSchema=[bool]$invocation.nativeSchema;omitted=@($invocation.omitted);attempts=$attempt;seconds=$seconds;quota=$quota.state;result=$result}
    if($OutputFolder){[IO.File]::WriteAllText((Join-Path $OutputFolder 'result.json'),(ConvertTo-SBJson $outcome),$utf8)}
    $outcome
}
function Get-SBEnrichmentGaps($Readiness) {
    # #608: the task fields a proposal may fill, from the readiness checks: description and stream (scope), acceptance, requires (tools).
    $gaps=@()
    foreach($c in @($Readiness.checks)){
        if($c.passed){continue}
        switch([string]$c.check){
            'scope' {foreach($m in @($c.missing)){if($m -in @('description','stream')){$gaps+=[string]$m}}}
            'acceptance' {$gaps+='acceptance'}
            'tools' {$gaps+='requires'}
        }
    }
    @($gaps|Select-Object -Unique)
}
function New-SBTaskEnrichPrompt($Task,$Readiness,[string[]]$Gaps,[string[]]$Streams=@()) {
    # #608: one-shot prompt of the light model for an incomplete task: the task, the gaps, and what it must never do.
    @(
        '# Task enrichment proposal',
        "Propose the missing detail of task $($Task['id']) of this repository. The current directory is its checkout: read code and files with your read-only tools when the detail depends on them.",
        "The deterministic readiness assessment found these gaps: $((@($Readiness.missing)) -join ', '). You may fill only: $(if($Gaps.Count){$Gaps -join ', '}else{'nothing (answer with null fields and questions)'}); every other proposal field must be null.",
        'Rules: derive everything from the task text, its provenance and the repository; do not invent requirements, scope, consent, approvals, decisions or evidence; do not change status, execution, priority, dependencies or waits. When the detail cannot be derived, leave the field null and ask a question instead.',
        $(if($Streams.Count){"Known streams of this tracker: $($Streams -join ', ')."}else{$null}),
        '',
        '## Task (tracker JSON)',
        (ConvertTo-SBJson $Task)
    ).Where({$null -ne $_}) -join "`n"
}
function Test-SBEnrichmentProposal($Result,[string[]]$Gaps,[string]$TaskId) {
    # #608: semantic checks after the schema: the proposal is about this task, fills only gaps, and names only known capabilities.
    # Fields outside the gaps are discarded with their name; an empty proposal with no question is not a proposal.
    $p=$Result['proposal'];$kept=[ordered]@{};$discarded=@()
    foreach($name in @('description','acceptance','stream','requires')){
        $value=$p[$name]
        if($null -eq $value -or ($value -is [string] -and !$value.Trim()) -or ($value -is [array] -and !@($value|Where-Object {([string]$_).Trim()}).Count)){continue}
        if($name -cnotin $Gaps){$discarded+=$name;continue}
        if($name -eq 'requires'){
            $known=@(Get-SBTaskRequiresValues)
            $bad=@(@($value)|Where-Object {[string]$_ -cnotin $known})
            if($bad.Count){$discarded+='requires';continue}
        }
        $kept[$name]=if($value -is [array]){@($value|ForEach-Object {([string]$_).Trim()}|Where-Object {$_})}else{([string]$value).Trim()}
    }
    $errors=@()
    if([string]$Result['taskId'] -cne $TaskId){$errors+='taskId'}
    if(!$kept.Count -and !@($Result['questions']).Count){$errors+='empty'}
    [ordered]@{valid=($errors.Count -eq 0);errors=$errors;proposal=$kept;discarded=$discarded}
}
function Invoke-SBTaskEnrichment {
    # #608: the light model only when the readiness assessment finds gaps; complete tasks never start the CLI. The answer is validated
    # against config/analysis/enrich.schema.json and the semantic rules, then stored as proposal.json in -OutputFolder (never applied here).
    param([Parameter(Mandatory)]$Task,$Tasks=@(),$Decisions=$null,[Parameter(Mandatory)][string]$Provider,[string]$Model,[string]$Effort,
        [Parameter(Mandatory)][string]$CheckoutPath,[Parameter(Mandatory)][string]$OutputFolder,[string]$BrainRoot,[string]$AgentPath,$Capabilities,
        [int]$TimeoutSeconds=600,[switch]$AllowCustomModel)
    $readiness=Get-SBTaskReadiness $Task $Tasks $Decisions
    $gaps=@(Get-SBEnrichmentGaps $readiness)
    $out=[ordered]@{called=$false;taskId=[string]$Task['id'];readiness=$readiness;gaps=$gaps;proposalPath=$null;sha256=$null}
    if($readiness.ready){$out.reason='ready';return $out}
    $streams=@(@($Tasks)|ForEach-Object {if($_ -is [Collections.IDictionary] -and $_['extensions'] -is [Collections.IDictionary]){[string]$_.extensions['stream']}}|Where-Object {$_}|Sort-Object -Unique)
    $prompt=New-SBTaskEnrichPrompt $Task $readiness $gaps $streams
    $schema=Join-Path $PSScriptRoot '../config/analysis/enrich.schema.json'
    $shot=Invoke-SBAgentOneShot -Provider $Provider -Model $Model -Effort $Effort -Prompt $prompt -SchemaPath $schema -CheckoutPath $CheckoutPath -OutputFolder $OutputFolder `
        -BrainRoot $BrainRoot -AgentPath $AgentPath -Capabilities $Capabilities -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:$AllowCustomModel
    $out.called=$true
    $check=Test-SBEnrichmentProposal $shot.result $gaps ([string]$Task['id'])
    if(!$check.valid){throw (New-SBError 'analysis.output.invalid' @($Provider,$shot.attempts,($check.errors -join '; ')))}
    $record=[ordered]@{schemaVersion=1;kind='task-enrichment';status='proposed';taskId=[string]$Task['id'];seq=$Task['seq'];createdAt=(Get-SBNow).ToString('o')
        provider=$shot.provider;model=$shot.model;effort=$shot.effort;role=$shot.role;attempts=$shot.attempts
        readiness=$readiness;gaps=$gaps;summary=[string]$shot.result['summary'];proposal=$check.proposal;discarded=$check.discarded;questions=@($shot.result['questions'])}
    $path=Join-Path $OutputFolder 'proposal.json'
    [IO.File]::WriteAllText($path,(ConvertTo-SBJson $record),[Text.UTF8Encoding]::new($false))
    $out.proposalPath=$path;$out.sha256=Get-SBFileHash $path;$out.proposal=$record
    $out
}
function Test-SBDirectiveText([string]$Text) {
    # The same portability rules approve-revision.ps1 applies to repository directive texts.
    !($Text -match '(?im)<!--\s*secondbrain:|(?<![A-Za-z0-9+.-])[A-Z]:[\\/]|(?<![\w/])/(?:Users|home)/|\{\{')
}
function ConvertTo-SBDirectivesMarkdown($Result) {
    # Sections of a directive proposal as the Markdown that goes into AGENTS.managed.md.
    (@($Result['sections'])|ForEach-Object {'## '+([string]$_.title).Trim()+"`n`n"+([string]$_.body).Trim()}) -join "`n`n"
}
Export-ModuleMember -Function @('Get-SBAnalysisSchemaPath','Get-SBLightModel','Get-SBPromptCardText','New-SBDirectivesAnalysisPrompt','New-SBTaskAnalysisPrompt','Invoke-SBAgentOneShot','Get-SBEnrichmentGaps','New-SBTaskEnrichPrompt','Test-SBEnrichmentProposal','Invoke-SBTaskEnrichment','Test-SBDirectiveText','ConvertTo-SBDirectivesMarkdown')
