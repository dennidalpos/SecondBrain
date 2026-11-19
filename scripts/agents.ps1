#requires -Version 7.5
<#
.SYNOPSIS
Agent CLIs for the task runner and the desktop orchestrator: capability probe, repository-specific directives and one-shot analyses.
.DESCRIPTION
-Probe [-Provider claude|codex|gemini] prints, for each agent CLI, whether it is installed, its version, the flags of its --help,
the models and effort levels it exposes (each with its source: probe or config; the fallback table only validates a typed model), its
status (ready, not-found, not-responding), where it was found (path, search folder or Store package) and its default light model
(roles.light of config/agent-models.json). Providers are probed in parallel.
-Clients adds the IDEs and AI clients detected on the workstation (scripts/ide-detect.ps1), each with the runner provider it maps to,
if any, and why it cannot be driven otherwise (no headless CLI). Read-only.
-Directives -RepositoryPath <checkout> prints the repository directive files (AGENTS.md and its managed block), the dossier-specific
directives (AGENTS.managed.md), the global and common blocks every session loads, AGENTS.md outside the managed blocks, the repository
block as it would be composed and the character counts against the startup budget. Read-only.
Add -DirectivesFile <markdown> to prepare a proposal for that text in a work folder (work.ps1, category work) and preview it with
approve-revision.ps1 -Preview; nothing in the dossier or the checkout changes. The output carries proposalPath and proposalHash.
-Directives -RepositoryPath <checkout> -ProposalPath <folder> -ExpectedProposalHash <hash> -Authorization <reference> -Apply approves the
reviewed proposal with approve-revision.ps1 and aligns the repository with secondbrain.ps1 -Sync -Repository <identity>.
-Analyze -Kind directives|task -RepositoryPath <checkout> -Provider <one> [-Model] [-Effort] [-TaskId] runs one read-only analysis with
the agent CLI (light model by default; analysis.directives or analysis.task) in a work folder and prints its validated JSON. -Kind task-resolve -AnalysisPath
<folder> -AnswersFile <json> gives the owner's answers and runs the next round (at most three). -Kind task-view -AnalysisPath <folder> reopens it read-only. -Kind task-apply -AnalysisPath <folder>
-Authorization <reference> writes the reviewed result to the tracker through knowledge.ps1 -UpdateTaskId (ledger mode analysis).
-Kind task-enrich -TaskId <id> calls the light model only when the readiness assessment finds gaps: the schema-validated proposal stays
in proposal.json of a work folder and the task records only extensions.enrichment (path, hash, status proposed); complete tasks never call it.
-Kind prompt-draft -Goal <one line> -Provider <one> asks the light model for the RCTFE fields of a user prompt (read-only, empty scratch folder, nothing saved).
Without a mode the script lists the modes and exits 2.
#>
[CmdletBinding()]
param([switch]$Probe,[ValidateSet('claude','codex','gemini')][string[]]$Provider,[switch]$Clients,
    [switch]$Directives,[string]$RepositoryPath,[string]$DirectivesFile,[string]$ProposalPath,
    [ValidatePattern('^$|^[0-9A-Fa-f]{64}$')][string]$ExpectedProposalHash,[string]$Authorization,[switch]$Apply,
    [switch]$Analyze,[ValidateSet('directives','task','task-enrich','task-enrich-view','prompt-draft','task-view','task-resolve','task-apply')][string]$Kind,[string]$Model,[string]$Effort,[switch]$AllowCustomModel,
    [string]$TaskId,[string]$Goal,[string]$AnalysisPath,[string]$AnswersFile,[ValidateRange(60,3600)][int]$TimeoutSeconds=600,
    [string]$ConfigPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAdapters.psm1')
Add-SBMessages @{
    'agents.usage' = @{ en = 'No mode given. Use -Probe [-Provider claude|codex|gemini], -Directives -RepositoryPath <checkout> [-DirectivesFile <md>] (preview) or with -ProposalPath -ExpectedProposalHash -Authorization -Apply, or -Analyze -Kind directives|task|task-resolve|task-apply' }
    'agents.repository.required' = @{ en = '-Directives and -Analyze need -RepositoryPath with the path of a managed checkout' }
    'agents.repository.unresolved' = @{ en = 'Checkout not bound to an active dossier: {0}. Register it with secondbrain.ps1 -AddRepo' }
    'agents.directives.file' = @{ en = 'Directives file not found: {0}' }
    'agents.apply.required' = @{ en = '-Apply needs -ProposalPath, -ExpectedProposalHash and -Authorization of the reviewed proposal' }
    'agents.step.failed' = @{ en = '{0} ended with exit code {1}: {2}' }
    'agents.analysis.provider' = @{ en = '-Analyze needs exactly one -Provider (claude, codex or gemini)' }
    'agents.analysis.goal' = @{ en = '-Kind prompt-draft needs -Goal: one line of at most 600 characters' }
    'agents.analysis.task' = @{ en = '-Kind task needs -TaskId of the task to analyze' }
    'agents.analysis.path' = @{ en = 'Invalid analysis folder: {0}. Use the analysisPath returned by -Kind task' }
    'agents.analysis.answers' = @{ en = 'Invalid answers in {0}: a JSON array of objects with questionId, question and answer is required' }
    'agents.analysis.rounds' = @{ en = 'The maximum of {0} question rounds is reached: apply the result or start the analysis again' }
    'agents.analysis.unresolved' = @{ en = 'The last round still asks for answers (verdict {0}): answer the questions before applying' }
    'agents.analysis.awaiting' = @{ en = 'The task awaits {0}: the analysis cannot clear the wait without an explicit answer of the owner' }
    'agents.analysis.authorization' = @{ en = '-Kind task-apply needs -Authorization (reference to the owner confirmation)' }
}
$brain=(Get-SBBrainRootPath)
$configArgs=if($ConfigPath){@('-ConfigPath',$ConfigPath)}else{@()}
$utf8=[Text.UTF8Encoding]::new($false)
$maxRounds=3
function Invoke-AgentsStep([string]$Script,[string[]]$StepArgs,[int[]]$AllowedExit=@(0)){
    # Child SecondBrain CLI: JSON on stdout, diagnostics on stderr; a non-zero exit is reported with its message.
    $path=Join-Path $PSScriptRoot $Script
    $errFile=[IO.Path]::GetTempFileName()
    try{
        $out=(& pwsh -NoProfile -File $path @StepArgs 2>$errFile|Out-String)
        $code=$LASTEXITCODE
        $err=[IO.File]::ReadAllText($errFile)
    }finally{Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue}
    if($code -notin $AllowedExit){throw (New-SBError 'agents.step.failed' @($Script,$code,($err+$out).Trim()))}
    $i=$out.IndexOfAny([char[]]@('[','{'))
    if($i -lt 0){return $null}
    $value=$out.Substring($i)|ConvertFrom-Json -AsHashtable
    if($value -is [hashtable]){$value.exitCode=$code}
    $value
}
function Get-AgentsRepository([string]$Path){
    if(!$Path){throw (New-SBError 'agents.repository.required')}
    $full=[IO.Path]::GetFullPath($Path)
    $context=Invoke-AgentsStep 'prompts.ps1' (@('-Context','-RepositoryPath',$full)+$configArgs)
    $repo=@($context.repositories|Where-Object {$_ -and $_.identity -and $_.dossier})
    if($repo.Count -ne 1){throw (New-SBError 'agents.repository.unresolved' @($full))}
    $repo[0]
}
function Get-AgentsDirectiveBlocks($Repo){
    # What every session of the repository loads besides the startup package: the global block (IDE instructions), the common repository
    # block and AGENTS.md outside the managed blocks; plus the dossier-specific text and the repository block composed from it.
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Portable.psm1')
    $global=try{Get-SBPortableGlobal $brain}catch{''}
    $commonPath=Join-Path $brain 'direttive/AGENTS.repo.managed.md'
    $common=if(Test-Path -LiteralPath $commonPath -PathType Leaf){(Read-SBText $commonPath).Trim()}else{''}
    $agentsFile=[string]$Repo.agents
    $agentsText=if($agentsFile -and (Test-Path -LiteralPath $agentsFile -PathType Leaf)){Read-SBText $agentsFile}else{''}
    $outside=([regex]::Replace($agentsText,'(?s)<!-- secondbrain:([\w-]+):begin -->.*?<!-- secondbrain:\1:end -->','')).Trim()
    $dossierFile=Join-Path $Repo.dossier 'AGENTS.managed.md'
    $current=if(Test-Path -LiteralPath $dossierFile -PathType Leaf){Read-SBText $dossierFile}else{''}
    @{global=$global;common=$common;agentsFile=$agentsFile;agentsText=$agentsText;outside=$outside;dossier=$current}
}
function Get-AgentsComposedBlock([string]$Common,[string]$Specific){
    # The repository block as secondbrain.ps1 -Sync would write it for the given specific text (approval aside): stamp, common body, specific text.
    $revision=Get-SBApprovedDirectiveRevision $brain
    $stamp=if($revision){'Common directives applied: revision **'+$revision.version+'** — '+$revision.date+'.'}else{''}
    (@($stamp,$Common.Trim(),$Specific.Trim())|Where-Object {$_}) -join "`n`n"
}
function Get-AgentsCounts($Blocks,[string]$Specific){
    $composed=Get-AgentsComposedBlock $Blocks.common $Specific
    $budget=25000
    $loaded=$Blocks.global.Length+$Blocks.outside.Length+$composed.Length
    [ordered]@{global=$Blocks.global.Length;common=$Blocks.common.Length;dossier=$Specific.Length;agentsOutside=$Blocks.outside.Length;composed=$composed.Length;loaded=$loaded;budget=$budget;percent=[math]::Round(100*$loaded/$budget,1)}
}
function Initialize-AgentsWork($Repo,[string]$Slug,[string]$Task){
    [string](Invoke-AgentsStep 'work.ps1' (@('-Repository',[string]$Repo.identity,'-Category','work','-Slug',$Slug,'-Init','-Task',$Task,'-Client','orchestrator')+$configArgs)).root
}
function Close-AgentsWork($Repo,[string]$Slug){
    try{[void](Invoke-AgentsStep 'work.ps1' (@('-Repository',[string]$Repo.identity,'-Category','work','-Slug',$Slug,'-Close')+$configArgs))}catch{[void]$_}
}
function Read-AgentsAnalysis([string]$Path){
    # The state of a task analysis lives in its work folder (analysis.json), so the window can close between rounds.
    $full=if($Path){[IO.Path]::GetFullPath($Path)}else{''}
    $file=if($full){Join-Path $full 'analysis.json'}else{''}
    if(!$file -or (Split-Path -Leaf $full) -notmatch '^\d{8}-analysis-task-\d+-\d{6}$' -or !(Test-Path -LiteralPath $file -PathType Leaf)){throw (New-SBError 'agents.analysis.path' @($Path))}
    $state=Read-SBText $file|ConvertFrom-Json -AsHashtable -Depth 40 -DateKind String
    if($state -isnot [hashtable] -or $state.schemaVersion -ne 1 -or !$state.taskId -or $state.rounds -isnot [array]){throw (New-SBError 'agents.analysis.path' @($Path))}
    @{path=$full;file=$file;state=$state}
}
function Save-AgentsAnalysis($Analysis){[IO.File]::WriteAllText($Analysis.file,(ConvertTo-SBJson $Analysis.state),$utf8)}
function Get-AgentsTaskContext($Repo,[string]$Id){
    # The task as the tracker holds it (archived included), why the runner skips it, and the status of its dependencies.
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.TaskRunner.psm1')
    $detail=Invoke-AgentsStep 'knowledge.ps1' (@('-Task',$Id,'-CheckoutPath',[string]$Repo.checkout)+$configArgs)
    $task=$detail.task
    $object=ConvertTo-SBJson $task|ConvertFrom-Json
    $reason=Get-SBRunnerExclusionReason $object
    $active=@(Invoke-AgentsStep 'knowledge.ps1' (@('-Tasks','-CheckoutPath',[string]$Repo.checkout)+$configArgs))
    $statusById=@{};foreach($t in $active){if($t -is [hashtable] -and $t.ContainsKey('id')){$statusById[[string]$t.id]=[string]$t.status}}
    $deps=@(@($task['dependencies'])|Where-Object {$_}|ForEach-Object {
        $depId=[string]$_['id'];$depRepo=[string]$_['repository']
        $label=if($depRepo){"$depRepo#$depId"}else{$depId}
        @{id=$label;status=$(if($depRepo){'other-repository'}elseif($statusById.ContainsKey($depId)){$statusById[$depId]}else{'archived'})}
    })
    $open=@($deps|Where-Object {$_.status -notin @('done','archived')})
    if(!$reason -and $open.Count){$reason='dependency:'+((@($open|ForEach-Object {$_.id})) -join ',')}
    @{task=$task;reason=$reason;dependencies=$deps}
}
function Invoke-AgentsTaskRound($Repo,$Analysis,$Context){
    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
    $state=$Analysis.state
    $round=@($state.rounds).Count+1
    $prompt=New-SBTaskAnalysisPrompt -BrainRoot $brain -Task $Context.task -Reason $Context.reason -Dependencies $Context.dependencies -Rounds $state.rounds -Language $state.language -Round $round -MaxRounds $maxRounds
    $out=Invoke-SBAgentOneShot -Provider $state.provider -Model $state.model -Effort $state.effort -Prompt $prompt -SchemaPath (Get-SBAnalysisSchemaPath $brain 'task') `
        -CheckoutPath ([string]$Repo.checkout) -OutputFolder (Join-Path $Analysis.path "round-$round") -BrainRoot $brain -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:$AllowCustomModel
    if(!$state.model -and $out.model){$state.model=$out.model}
    if(!$state.effort -and $out.effort){$state.effort=$out.effort}
    $state.rounds=@($state.rounds)+@([ordered]@{round=$round;at=(Get-SBNow).ToString('o');result=$out.result;answers=@();attempts=$out.attempts;seconds=$out.seconds;nativeSchema=$out.nativeSchema})
    Save-AgentsAnalysis $Analysis
    $out
}
function Get-AgentsAnalysisView($Analysis,$Context){
    $state=$Analysis.state
    $last=@($state.rounds)[-1]
    [ordered]@{
        analysisPath=$Analysis.path;taskId=$state.taskId;seq=$state.seq;repository=$state.repository;provider=$state.provider;model=$state.model;effort=$state.effort
        round=@($state.rounds).Count;maxRounds=$maxRounds;reason=$Context.reason;dependencies=$Context.dependencies
        task=[ordered]@{id=$Context.task['id'];seq=$Context.task['seq'];title=$Context.task['title'];status=$Context.task['status'];execution=$Context.task['execution'];description=$Context.task['description'];acceptance=@($Context.task['acceptance']);extensions=$Context.task['extensions']}
        result=$last.result;answered=@(@($state.rounds)|ForEach-Object {@($_.answers)}|Where-Object {$_})
    }
}
try{
    if($Probe){
        $ids=if($Provider){@($Provider)}else{@(Get-SBAgentProviderIds)}
        $agents=@(Get-SBAgentCapabilitiesAll -Provider $ids -BrainRoot $brain)
        Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
        foreach($a in $agents){$a.light=Get-SBLightModel $brain ([string]$a.provider)}
        $output=[ordered]@{agents=$agents}
        if($Clients){
            # IDEs and clients seen on the workstation: only the ones with a headless CLI of a runner provider can run tasks.
            Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
            $map=@{'Claude Code'='claude';'Codex'='codex';'Gemini CLI'='gemini'}
            $output.clients=@(@(Get-SBIDEDetection '')|ForEach-Object {
                $name=[string]$_.name;$mapped=if($map.ContainsKey($name)){$map[$name]}else{$null}
                $agent=if($mapped){@($agents|Where-Object {$_.provider -eq $mapped})[0]}else{$null}
                [ordered]@{name=$name;confidence=$_.confidence;provider=$mapped;runnable=[bool]($agent -and $agent.status -eq 'ready');reason=$(if(!$mapped){'no-headless-cli'}elseif(!$agent -or $agent.status -ne 'ready'){'cli-'+$(if($agent){$agent.status}else{'not-found'})}else{$null})}
            })
        }
        ConvertTo-SBJson $output
        exit 0
    }
    if($Analyze){
        $repo=if($Kind -eq 'prompt-draft'){$null}else{Get-AgentsRepository $RepositoryPath}
        $lang='en'
        if($Kind -in @('directives','task','task-enrich','prompt-draft') -and @($Provider).Count -ne 1){throw (New-SBError 'agents.analysis.provider')}
        switch($Kind){
            'directives' {
                Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
                $blocks=Get-AgentsDirectiveBlocks $repo
                $slug='analysis-directives-'+(Get-SBNow).LocalDateTime.ToString('HHmmss')
                $root=Initialize-AgentsWork $repo $slug 'Analisi delle direttive di repository (orchestratore, analysis.directives)'
                try{
                    $counts=Get-AgentsCounts $blocks $blocks.dossier
                    $prompt=New-SBDirectivesAnalysisPrompt -BrainRoot $brain -Identity ([string]$repo.identity) -GlobalText $blocks.global -CommonText $blocks.common -DossierText $blocks.dossier -AgentsOutside $blocks.outside -Budget $counts.budget -UsedCharacters ($counts.loaded-$counts.dossier) -Language $lang
                    $out=Invoke-SBAgentOneShot -Provider $Provider[0] -Model $Model -Effort $Effort -Prompt $prompt -SchemaPath (Get-SBAnalysisSchemaPath $brain 'directives') -CheckoutPath ([string]$repo.checkout) -OutputFolder $root -BrainRoot $brain -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:$AllowCustomModel
                    $markdown=ConvertTo-SBDirectivesMarkdown $out.result
                    ConvertTo-SBJson ([ordered]@{
                        identity=$repo.identity;folder=$root;provider=$out.provider;model=$out.model;effort=$out.effort;role=$out.role;attempts=$out.attempts;seconds=$out.seconds;nativeSchema=$out.nativeSchema
                        markdown=$markdown;portable=(Test-SBDirectiveText $markdown);sections=@($out.result.sections);coveredElsewhere=@($out.result.coveredElsewhere);warnings=@($out.result.warnings)
                        counts=(Get-AgentsCounts $blocks $markdown)
                    })
                }finally{Close-AgentsWork $repo $slug}
                exit 0
            }
            'task' {
                if(!$TaskId){throw (New-SBError 'agents.analysis.task')}
                $context=Get-AgentsTaskContext $repo $TaskId
                $slug='analysis-task-'+[string]$context.task['seq']+'-'+(Get-SBNow).LocalDateTime.ToString('HHmmss')
                $root=Initialize-AgentsWork $repo $slug ("Analisi di autonomia del task $TaskId (orchestratore, analysis.task)")
                $analysis=@{path=$root;file=(Join-Path $root 'analysis.json');state=[ordered]@{schemaVersion=1;taskId=[string]$context.task['id'];seq=$context.task['seq'];repository=[string]$repo.identity;slug=$slug;provider=$Provider[0];model=$Model;effort=$Effort;language=$lang;createdAt=(Get-SBNow).ToString('o');rounds=@();applied=$null}}
                Save-AgentsAnalysis $analysis
                [void](Invoke-AgentsTaskRound $repo $analysis $context)
                ConvertTo-SBJson (Get-AgentsAnalysisView $analysis $context)
                exit 0
            }
            'task-enrich' {
                # #608: the light model only when the readiness assessment finds gaps; the validated proposal stays in a work folder and the
                # task gets only extensions.enrichment (path, hash, status=proposed). Nothing of the proposal is applied here.
                if(!$TaskId){throw (New-SBError 'agents.analysis.task')}
                Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
                Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Decisions.psm1')
                Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
                $context=Get-AgentsTaskContext $repo $TaskId
                $peers=@(Invoke-AgentsStep 'knowledge.ps1' (@('-Tasks','-CheckoutPath',[string]$repo.checkout)+$configArgs))
                $decisions=try{(Read-SBDecisions ([string]$repo.dossier) ([string]$repo.identity)).data}catch{$null}
                $readiness=Get-SBTaskReadiness $context.task $peers $decisions
                if($readiness.ready){ConvertTo-SBJson ([ordered]@{called=$false;reason='ready';taskId=$context.task['id'];readiness=$readiness});exit 0}
                $slug='enrich-task-'+[string]$context.task['seq']+'-'+(Get-SBNow).LocalDateTime.ToString('HHmmss')
                $root=Initialize-AgentsWork $repo $slug ("Light-model enrichment proposal for task $TaskId (#608)")
                try{
                    $agentPath=if($env:SECONDBRAIN_TEST_ROOT -and $env:SB_AGENTS_TEST_AGENT_PATH){$env:SB_AGENTS_TEST_AGENT_PATH}else{$null}
                    $out=Invoke-SBTaskEnrichment -Task $context.task -Tasks $peers -Decisions $decisions -Provider $Provider[0] -Model $Model -Effort $Effort -CheckoutPath ([string]$repo.checkout) -OutputFolder $root -BrainRoot $brain -AgentPath $agentPath -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:$AllowCustomModel
                    $written=Invoke-AgentsStep 'knowledge.ps1' (@('-UpdateTaskId',[string]$context.task['id'],'-EnrichmentFile',$out.proposalPath,'-CheckoutPath',[string]$repo.checkout)+$configArgs) -AllowedExit @(0,5)
                    $out.pointer=if($written -and $written.exitCode -eq 5){'deferred'}else{'recorded'}
                    ConvertTo-SBJson $out
                }finally{Close-AgentsWork $repo $slug}
                exit 0
            }
            'prompt-draft' {
                # #753: the light model drafts the RCTFE fields of a user prompt from a one-line goal. Read-only, in an empty scratch folder; the
                # draft goes back to the window, which fills the wizard: nothing is saved here (Preview and Save stay with the person).
                if(!$Goal -or !$Goal.Trim() -or $Goal.Length -gt 600){throw (New-SBError 'agents.analysis.goal')}
                Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentAnalysis.psm1')
                $scratch=Join-Path ([IO.Path]::GetTempPath()) ('sb-prompt-draft-'+(New-SBId))
                [void][IO.Directory]::CreateDirectory($scratch)
                try{
                    $agentPath=if($env:SECONDBRAIN_TEST_ROOT -and $env:SB_AGENTS_TEST_AGENT_PATH){$env:SB_AGENTS_TEST_AGENT_PATH}else{$null}
                    $out=Invoke-SBPromptDraft -Goal $Goal -Provider $Provider[0] -Model $Model -Effort $Effort -CheckoutPath $scratch -BrainRoot $brain -AgentPath $agentPath -TimeoutSeconds $TimeoutSeconds -AllowCustomModel:$AllowCustomModel
                    ConvertTo-SBJson $out
                }finally{Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue}
                exit 0
            }
            'task-enrich-view' {
                # #645: read-only view of the stored enrichment proposal of a task: the pointer, whether the file still has the recorded
                # hash, and the proposal record. The reviewed apply or reject is knowledge.ps1 -ApplyEnrichment / -RejectEnrichment.
                if(!$TaskId){throw (New-SBError 'agents.analysis.task')}
                $context=Get-AgentsTaskContext $repo $TaskId
                $raw=if($context.task['extensions'] -is [Collections.IDictionary]){$context.task['extensions']['enrichment']}else{$null}
                $view=[ordered]@{taskId=[string]$context.task['id'];seq=$context.task['seq'];title=[string]$context.task['title'];pointer=$null;hashMatches=$false;proposal=$null}
                if($raw){
                    $pointer=$raw
                    $file=[IO.Path]::GetFullPath((Join-Path $brain ([string]$pointer['path'])))
                    if(!$file.StartsWith([IO.Path]::GetFullPath($brain),[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'tracker.enrichment.invalid')}
                    $view.pointer=$pointer
                    if(Test-Path -LiteralPath $file -PathType Leaf){
                        $view.hashMatches=((Get-SBFileHash $file) -ieq [string]$pointer['sha256'])
                        $view.proposal=Read-SBJson $file $null
                    }
                }
                ConvertTo-SBJson $view
                exit 0
            }
            'task-view' {
                # Read-only: the state of an analysis started earlier (the window reopens it without a new agent call).
                $analysis=Read-AgentsAnalysis $AnalysisPath
                $context=Get-AgentsTaskContext $repo ([string]$analysis.state.taskId)
                $view=Get-AgentsAnalysisView $analysis $context
                $view.applied=$analysis.state['applied']
                ConvertTo-SBJson $view
                exit 0
            }
            'task-resolve' {
                $analysis=Read-AgentsAnalysis $AnalysisPath
                if(!$AnswersFile -or !(Test-Path -LiteralPath $AnswersFile -PathType Leaf)){throw (New-SBError 'agents.analysis.answers' @($AnswersFile))}
                try{$answers=@(Read-SBText $AnswersFile|ConvertFrom-Json -AsHashtable)}catch{throw (New-SBError 'agents.analysis.answers' @($AnswersFile))}
                if(!$answers.Count -or @($answers|Where-Object {$_ -isnot [hashtable] -or !$_['question'] -or !$_['answer']}).Count){throw (New-SBError 'agents.analysis.answers' @($AnswersFile))}
                if(@($analysis.state.rounds).Count -ge $maxRounds){throw (New-SBError 'agents.analysis.rounds' @($maxRounds))}
                $stamp=(Get-SBNow).ToString('o')
                @($analysis.state.rounds)[-1].answers=@($answers|ForEach-Object {[ordered]@{questionId=[string]$_['questionId'];question=[string]$_.question;answer=[string]$_.answer;at=$stamp}})
                Save-AgentsAnalysis $analysis
                $context=Get-AgentsTaskContext $repo ([string]$analysis.state.taskId)
                [void](Invoke-AgentsTaskRound $repo $analysis $context)
                ConvertTo-SBJson (Get-AgentsAnalysisView $analysis $context)
                exit 0
            }
            'task-apply' {
                if(!$Authorization){throw (New-SBError 'agents.analysis.authorization')}
                $analysis=Read-AgentsAnalysis $AnalysisPath
                $state=$analysis.state
                $result=@($state.rounds)[-1].result
                if($result.verdict -notin @('autonomous-now','not-automatable')){throw (New-SBError 'agents.analysis.unresolved' @($result.verdict))}
                $context=Get-AgentsTaskContext $repo ([string]$state.taskId)
                $task=$context.task
                $ext=if($task['extensions'] -is [hashtable]){$task.extensions}else{@{}}
                $answers=@(@($state.rounds)|ForEach-Object {@($_.answers)}|Where-Object {$_})
                $updateArgs=@('-UpdateTaskId',[string]$state.taskId,'-CheckoutPath',[string]$repo.checkout)
                $decisionsFile=$null
                if($answers.Count){
                    $decisionsFile=Join-Path $analysis.path 'decisions.json'
                    [IO.File]::WriteAllText($decisionsFile,(ConvertTo-SBJson @($answers|ForEach-Object {[ordered]@{questionId=$_.questionId;question=$_.question;answer=$_.answer;at=$_.at;decidedBy='owner (orchestrator)'}})),$utf8)
                    $updateArgs+=@('-DecisionsFile',$decisionsFile)
                }
                if($result.verdict -eq 'autonomous-now'){
                    $call=@(@($result.calls)|Where-Object {$_.name -eq 'propose_task_update'})|Select-Object -First 1
                    if(!$call){throw (New-SBError 'agents.analysis.unresolved' @($result.verdict))}
                    $u=$call.arguments
                    # A real wait of the owner is cleared only by an explicit answer recorded in this analysis.
                    $awaiting=[string]$ext['awaiting']
                    $newAwaiting=if($u['awaiting']){[string]$u.awaiting}else{''}
                    if($awaiting -and $awaiting -ne 'structural-completion' -and $newAwaiting -ne $awaiting -and !$answers.Count){throw (New-SBError 'agents.analysis.awaiting' @($awaiting))}
                    if($u['description']){$updateArgs+=@('-Description',[string]$u.description)}
                    $criteria=@(@($u['acceptance'])|Where-Object {$_}|ForEach-Object {([string]$_).Replace(';',',').Trim()})
                    if($criteria.Count){$updateArgs+=@('-Acceptance',($criteria -join ';'))}
                    $updateArgs+=@('-Execution',$(if($u['execution']){[string]$u.execution}else{'autonomous'}),'-Awaiting',$newAwaiting)
                    Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Tracker.psm1')
                    $requires=@(@($u['requires'])|Where-Object {$_ -and [string]$_ -cin (Get-SBTaskRequiresValues)})
                    $updateArgs+=@('-Requires',($requires -join ';'))
                    if($null -ne $u['dependencies']){$updateArgs+=@('-DependsOn',((@($u.dependencies)|Where-Object {$_}) -join ';'))}
                    if($u['stateReason']){$updateArgs+=@('-StateReason',[string]$u.stateReason)}
                    if([string]$task['status'] -in @('blocked','unknown')){$updateArgs+=@('-Status','todo')}
                }else{
                    $call=@(@($result.calls)|Where-Object {$_.name -eq 'mark_not_automatable'})|Select-Object -First 1
                    $why=if($call -and $call.arguments['reason']){[string]$call.arguments.reason}else{[string]$result.summary}
                    $updateArgs+=@('-StateReason',$why,'-Execution','user_required')
                }
                # The analysis tool is the executor of this write (ledger mode analysis); the owner confirmed it with -Authorization.
                $previous=$env:SECONDBRAIN_EXECUTOR
                try{
                    $env:SECONDBRAIN_EXECUTOR=(ConvertTo-Json ([ordered]@{tool=$state.provider;mode='analysis';model=$state.model;effort=$state.effort}) -Compress)
                    $written=Invoke-AgentsStep 'knowledge.ps1' (@($updateArgs)+$configArgs) -AllowedExit @(0,5)
                }finally{$env:SECONDBRAIN_EXECUTOR=$previous}
                $applied=if($written -and $written.exitCode -eq 5){'deferred'}else{$true}
                $state.applied=[ordered]@{at=(Get-SBNow).ToString('o');authorization=$Authorization;verdict=$result.verdict;state=$applied}
                Save-AgentsAnalysis $analysis
                Close-AgentsWork $repo ([string]$state.slug)
                ConvertTo-SBJson ([ordered]@{applied=$applied;taskId=$state.taskId;verdict=$result.verdict;analysisPath=$analysis.path;update=$written})
                exit 0
            }
            default {throw (New-SBError 'agents.usage')}
        }
    }
    if(!$Directives){throw (New-SBError 'agents.usage')}
    $repo=Get-AgentsRepository $RepositoryPath
    $relative=[IO.Path]::GetRelativePath($brain,(Join-Path $repo.dossier 'AGENTS.managed.md')).Replace('\','/')
    if($Apply){
        if(!$ProposalPath -or !$ExpectedProposalHash -or !$Authorization){throw (New-SBError 'agents.apply.required')}
        $approved=Invoke-AgentsStep 'approve-revision.ps1' (@('-ProposalPath',$ProposalPath,'-ExpectedProposalHash',$ExpectedProposalHash,'-Authorization',$Authorization)+$configArgs)
        $sync=Invoke-AgentsStep 'secondbrain.ps1' (@('-Sync','-Repository',[string]$repo.identity)+$configArgs)
        # The proposal folder (work/<date>-directives) is closed once applied, so its retention starts and it does not stay open.
        if((Split-Path -Leaf $ProposalPath) -match '^\d{8}-directives$'){try{[void](Invoke-AgentsStep 'work.ps1' (@('-Repository',[string]$repo.identity,'-Category','work','-Slug','directives','-Close')+$configArgs))}catch{[void]$_}}
        ConvertTo-SBJson @{applied=$true;identity=$repo.identity;approval=$approved;sync=$sync}
        exit 0
    }
    $blocks=Get-AgentsDirectiveBlocks $repo
    $agentsFile=$blocks.agentsFile
    $block=try{Get-SBManagedContent $blocks.agentsText 'repository'}catch{$null}
    $current=$blocks.dossier
    $result=[ordered]@{identity=$repo.identity;checkout=$repo.checkout;agentsFile=$agentsFile;managedBlock=$block;dossierDirectives=$current;dossierRelative=$relative
        globalBlock=$blocks.global;commonBlock=$blocks.common;agentsOutside=$blocks.outside;composedPreview=(Get-AgentsComposedBlock $blocks.common $current);counts=(Get-AgentsCounts $blocks $current);proposal=$null}
    if($DirectivesFile){
        $source=[IO.Path]::GetFullPath($DirectivesFile)
        if(!(Test-Path -LiteralPath $source -PathType Leaf)){throw (New-SBError 'agents.directives.file' @($source))}
        $text=Read-SBText $source
        # Proposal folder: README.md plus the dossier path of AGENTS.managed.md, as approve-revision.ps1 expects.
        $folder=Invoke-AgentsStep 'work.ps1' (@('-Repository',[string]$repo.identity,'-Category','work','-Slug','directives','-Init','-Task','Proposta direttive di repository (orchestratore)')+$configArgs)
        $root=[string]$folder.root
        $readme="# Repository directives proposal`n`nRepository: $($repo.identity)`nPrepared by scripts/agents.ps1 -Directives from the selected file.`n"
        [IO.File]::WriteAllText((Join-Path $root 'README.md'),$readme,$utf8)
        $target=Join-Path $root $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target))|Out-Null
        [IO.File]::WriteAllText($target,$text.TrimEnd()+"`n",$utf8)
        $preview=Invoke-AgentsStep 'approve-revision.ps1' (@('-ProposalPath',$root,'-Preview')+$configArgs)
        $result.proposal=[ordered]@{proposalPath=$root;proposalHash=$(if($preview -and $preview.ContainsKey('proposalHash')){$preview.proposalHash}else{$null});preview=$preview}
        $result.composedPreview=Get-AgentsComposedBlock $blocks.common $text
        $result.counts=Get-AgentsCounts $blocks $text
    }
    ConvertTo-SBJson $result
    exit 0
}catch{
    Write-Error $_ -ErrorAction Continue
    exit 2
}
