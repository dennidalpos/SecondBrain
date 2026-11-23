#requires -Version 7.5
<#
.SYNOPSIS
Browses and composes catalog workflows. Does not execute tasks or AI services.
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -List -Compact
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -List -Category quality
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -List -Json
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Json
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Show -Prompt QUA05 -Json
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Show -Prompt QUA05
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Compose -Prompt QUA05 -Objective 'Diagnose the Windows job'
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Preset wf-fix-defect -Objective 'Fix the login crash' -Skip review-change
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Packs
.EXAMPLE
pwsh -NoProfile -File scripts/prompts.ps1 -Packs -Pack site -Enable
#>
[CmdletBinding(DefaultParameterSetName='Home')]
param(
    [Parameter(ParameterSetName='Home')][switch]$Start,
    [Parameter(ParameterSetName='Home')][ValidateSet('home','maintenance','mcp')][string]$Menu='home',
    [Parameter(ParameterSetName='List')][switch]$List,
    [Parameter(ParameterSetName='List')][switch]$Compact,
    [Parameter(ParameterSetName='Home')][Parameter(ParameterSetName='List')][Parameter(ParameterSetName='Show')][switch]$Json,
    [Parameter(Mandatory,ParameterSetName='Show')][switch]$Show,
    [Parameter(Mandatory,ParameterSetName='Compose')][switch]$Compose,
    [Parameter(Mandatory,ParameterSetName='Preset')][string]$Preset,
    [Parameter(ParameterSetName='Preset')][string[]]$Skip,
    [Parameter(ParameterSetName='Preset')][hashtable]$Choose,
    [Parameter(Mandatory,ParameterSetName='Context')][switch]$Context,
    [Parameter(Mandatory,ParameterSetName='Show')]
    [Parameter(Mandatory,ParameterSetName='Compose')][ValidatePattern('^([A-Z]{2,4}[0-9]{2}|pmt-[0-9a-f]{8})$')][string]$Prompt,
    [Parameter(Mandatory,ParameterSetName='Packs')][switch]$Packs,
    [Parameter(ParameterSetName='Packs')][ValidateSet('site','llm')][string]$Pack,
    [Parameter(ParameterSetName='Packs')][switch]$Enable,
    [Parameter(ParameterSetName='Packs')][switch]$Disable,
    [Parameter(ParameterSetName='List')][string]$Category,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][string]$Objective,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][string]$OutputPath,
    [Parameter(ParameterSetName='Home')][Parameter(ParameterSetName='List')][Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][Parameter(ParameterSetName='Context')][string]$RepositoryPath,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][Parameter(ParameterSetName='Context')][string]$Repository,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][Parameter(ParameterSetName='Context')][string]$ProjectId,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][Parameter(ParameterSetName='Context')][string]$CheckoutPath,
    [Parameter(ParameterSetName='Compose')][Parameter(ParameterSetName='Preset')][Parameter(ParameterSetName='Context')][string]$CheckoutMapPath,
    [string]$ConfigPath,[string]$SessionId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Pending.psm1')
Add-SBMessages @{
    'promptscli.workstation.inactive' = @{ en = 'Workstation not activated: use sb activate (workstation.activate)' }
    'promptscli.context.incompatible' = @{ en = 'Incompatible context selections: use one context selection at a time' }
    'promptscli.goal.empty' = @{ en = 'Empty goal: give the goal with -Objective' }
    'promptscli.output.txt' = @{ en = 'New TXT output required: give -OutputPath a TXT file that does not exist yet' }
    'promptscli.bootstrap' = @{ en = 'Bootstrap: use the current SecondBrain checkout, with no preset paths.' }
    'promptscli.pack.action' = @{ en = 'Give exactly one of -Enable or -Disable with -Pack' }
    'promptscli.output.created' = @{ en = 'Created: {0}' }
}
$brain=(Get-SBBrainRootPath)
$lock=$null
try {
    # #474: prompt reads never integrate pending writes (knowledge.ps1 -FlushPending does).
    # Memory discovery must remain available even if the prompt catalog is broken.
    if(!$Context){$catalog=Read-SBWorkflowCatalog $brain}
    if(!$ConfigPath -and $PSCmdlet.ParameterSetName -in @('Context','Compose','Preset')){
        Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
        $candidateConfig=Get-SBHostConfigPath $brain
        if(Test-Path -LiteralPath $candidateConfig){$ConfigPath=$candidateConfig}
    }
    if($ConfigPath){$config=Read-SBConfiguration $ConfigPath -ReadOnly;$lock=Enter-SBOperation $config $SessionId -ReadOnly;Write-SBReadWarnings $lock $config}
    if($PSCmdlet.ParameterSetName -eq 'Home'){
        $homeState=Get-SBWorkflowState $brain $(if($RepositoryPath){$RepositoryPath}else{(Get-Location).Path})
        if($Json){ConvertTo-SBJson (ConvertTo-SBWorkflowHomeData $homeState)}else{Format-SBWorkflowHome $brain $catalog $homeState -Menu $Menu}
    } elseif($PSCmdlet.ParameterSetName -eq 'List' -and $Json){
        # Documented in docs/orchestratore.md: public catalog only, English text.
        ConvertTo-SBJson (ConvertTo-SBWorkflowCatalogData $catalog $Category -Packs @(Get-SBEnabledPromptPacks $brain))
    } elseif($PSCmdlet.ParameterSetName -eq 'List'){
        $listing=Format-SBWorkflowList $catalog $Category -Compact:$Compact -Packs @(Get-SBEnabledPromptPacks $brain)
        # #589: with -RepositoryPath, the private cards of that repository's dossier follow the public list; never without it.
        if($RepositoryPath){
            Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Knowledge.psm1')
            Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PrivateAssets.psm1')
            $listConfig=if($config){$config}else{try{Read-SBConfiguration -ReadOnly}catch{$null}}
            $privateRepo=Resolve-SBWorkingRepository $RepositoryPath @($(if($listConfig){$listConfig.bindings}))
            if($privateRepo){
                $privateSet=Read-SBPrivateAssets -Dossier (Join-Path $brain (Resolve-SBWorkingDossier $brain $privateRepo)) -Repository $privateRepo -PublicCatalog $catalog
                $listing=$listing.TrimEnd()+"`n"+(Format-SBPrivatePromptList $privateSet)
            }
        }
        $listing
    } elseif($PSCmdlet.ParameterSetName -eq 'Packs'){
        if($Pack -and ($Enable -eq $Disable)){throw (New-SBError 'promptscli.pack.action')}
        if($Pack){[void](Set-SBPromptPack $brain $Pack ([bool]$Enable));Get-SBMessage 'prompts.pack.changed' @($Pack,$(if($Enable){'enabled'}else{'hidden'}))}
        Format-SBPromptPackStatus $brain $catalog
    } elseif($Show){
        $resolution=Resolve-SBWorkflowPrompt $catalog $Prompt
        Assert-SBPromptPackEnabled $brain $resolution.prompt
        if($resolution.warning){Write-Warning $resolution.warning}
        $selected=@($resolution.prompt)
        $showBody=Read-SBWorkflowPrompt $brain $selected[0] $catalog
        if($Json){
            # Prompts tab (#722): one public card as JSON, English text.
            ConvertTo-SBJson ([ordered]@{schema='secondbrain.prompts.card';schemaVersion=1;id=$selected[0].id;code=$selected[0].code;kind=$selected[0].kind;summary=(Get-SBWorkflowField $selected[0] 'summary');text=$showBody})
        } else {
            Format-SBWorkflowCard $selected[0] $showBody
            $showBody
        }
    } else {
        if(!$ConfigPath -and $Compose -and (Resolve-SBWorkflowPrompt $catalog $Prompt).prompt.role -ceq 'workstation.activate'){
            $selected=@((Resolve-SBWorkflowPrompt $catalog $Prompt).prompt)
            Read-SBWorkflowPrompt $brain $selected[0] $catalog
            Get-SBMessage 'promptscli.bootstrap'
            exit 0
        }
        if(!$ConfigPath){throw (New-SBError 'promptscli.workstation.inactive')}
        if(($Repository -and $RepositoryPath) -or ($ProjectId -and ($Repository -or $RepositoryPath)) -or ($CheckoutPath -and $RepositoryPath)){throw (New-SBError 'promptscli.context.incompatible')}
        if($PSBoundParameters.ContainsKey('Objective') -and !$Objective.Trim()){throw (New-SBError 'promptscli.goal.empty')}
        $degraded=$null
        try{$resolved=Get-SBWorkflowContext -Config $config -RepositoryPath $RepositoryPath -Repository $Repository -ProjectId $ProjectId -CheckoutPath $CheckoutPath -CheckoutMapPath $CheckoutMapPath}
        catch{
            # Reduced mode: a Git checkout with no dossier still gets repository prompts (read, verify and code work), composed without SecondBrain context.
            # Central prompts and MEM/SYS writes to the dossier keep the error, as does any other context failure.
            $code=$_.Exception.Data['code']
            $candidate=if($Compose -and $code -eq 'prompts.dossier.unbound' -and !$Repository -and !$ProjectId){(Resolve-SBWorkflowPrompt $catalog $Prompt).prompt}else{$null}
            if(!$candidate -or $candidate.target -eq 'central' -or ($candidate.mode -eq 'write' -and $candidate.code -match '^(MEM|SYS)')){throw}
            $where=if($RepositoryPath){[IO.Path]::GetFullPath($RepositoryPath)}elseif($CheckoutPath){[IO.Path]::GetFullPath($CheckoutPath)}else{(Get-Location).Path}
            $degraded=(Get-SBWorkflowMessage 'home.degraded.compose' @(($where -replace '\\','/')))+"`n"+(Get-SBWorkflowMessage 'home.degraded')
            $resolved=@{repositories=@();project=$null;sourceRegistry=$null}
        }
        if($Context){ConvertTo-SBJson $resolved}
        else {
            if($Preset){
                $chosen=@{};if($Choose){foreach($k in $Choose.Keys){$chosen[[string]$k]=[string]$Choose[$k]}}
                $body=New-SBWorkflowPresetRun $brain $catalog $Preset $resolved $Objective -Skip @($Skip|Where-Object {$_}) -Choose $chosen
            } else {
            $resolution=Resolve-SBWorkflowPrompt $catalog $Prompt
            if($resolution.warning){Write-Warning $resolution.warning}
            $selected=@($resolution.prompt)
            $body=if($degraded){New-SBWorkflowComposition $brain $catalog $selected[0] $resolved $Objective -Standalone -Degraded $degraded}else{New-SBWorkflowComposition $brain $catalog $selected[0] $resolved $Objective}
            }
            if($OutputPath){
                $full=[IO.Path]::GetFullPath($OutputPath);Assert-SBPlainPath $full
                if($config.ContainsKey('mode') -and $config.mode -eq 'portable'){$full=Assert-SBCentralDataPath $brain $full}
                if([IO.Path]::GetExtension($full) -ne '.txt'){throw (New-SBError 'promptscli.output.txt')}
                $stream=[IO.FileStream]::new($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$stream.Write([Text.Encoding]::UTF8.GetBytes($body));$stream.Flush($true)}finally{$stream.Dispose()}
                Get-SBMessage 'promptscli.output.created' @($full)
            }else{$body}
        }
    }
    exit 0
} catch {if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; Write-Error $_ -ErrorAction Continue;exit 2} finally {Exit-SBOperation $lock}
