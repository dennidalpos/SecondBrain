#requires -Version 7.5
<#
.SYNOPSIS
Library management (#634): list, show and plan the retirement of prompts, workflows and agent definitions, with every reference named.
.DESCRIPTION
Read-only: nothing is written here. Retirement itself stays with the lifecycle commands (prompt-cards.ps1 -Operation retire, subagents.ps1 -Operation Retire).
-Operation List -Kind prompt|workflow|agent [-Query text]: items with ID, key, title, status, revision and the assets that use them (workflow steps for cards, tasks for workflows and agents).
-Operation Show -Kind -Id: the item with its preview text (card body, workflow steps, agent definition) and its references.
-Operation Retire -Kind -Id: the references that block the retirement (a retirement that would break an active asset is refused) and the plan of the lifecycle command.
A workflow has no retire procedure yet: its retirement is reported as unavailable, with the references that would block it.
.EXAMPLE
pwsh -NoProfile -File scripts/library.ps1 -Operation Retire -Kind prompt -Id pmt-0123abcd -Repository github.com/my-org/my-product
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('List','Show','Retire')][string]$Operation,
    [Parameter(Mandatory)][ValidateSet('prompt','workflow','agent')][string]$Kind,
    [Parameter(Mandatory)][string]$Repository,[string]$Query='',[string]$Id
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($m in 'Core','Access','Host','Entity','Knowledge','Prompts','PromptLifecycle','Subagents'){Import-Module (Join-Path $PSScriptRoot ('SecondBrain.'+$m+'.psm1'))}
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'library.invalid' = @{ en = 'Library: invalid or unknown {0}' }
    'library.workflow.noretire' = @{ en = 'A workflow has no retire procedure yet: it stays in the catalog' }
    'library.agent.referenced' = @{ en = 'Still used by {0}' }
}
$brain=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!(Test-SBRepositoryIdentity $Repository)){throw (New-SBError 'library.invalid' @('repository'))}
if($Operation -ne 'List' -and $Id -cnotmatch '^(pmt|wfl)-[0-9a-f]{8}$' -and $Id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$'){throw (New-SBError 'library.invalid' @('id'))}
$catalog=Read-SBWorkflowCatalog $brain
$flows=@(Read-SBPromptWorkflows $brain $catalog)
$dossier=Resolve-SBParaPath $brain (Resolve-SBWorkingDossier $brain $Repository)
$trackerPath=Join-Path $dossier 'tracker.json'
$tasks=@(if(Test-Path -LiteralPath $trackerPath -PathType Leaf){$t=Read-SBJson $trackerPath $null;if($t -is [Collections.IDictionary] -and $t.Contains('tasks')){$t.tasks}})
$open=@($tasks|Where-Object {$_ -is [Collections.IDictionary] -and $_.status -cnotin @('done','cancelled')})
function Get-TaskNaming([string]$Field,[string[]]$Keys) {
    # Open tasks that name the asset through extensions.card, extensions.workflow or extensions.subagents (an ID, a key, a role or a name).
    @($open|Where-Object {
        $e=if($_.Contains('extensions')){$_.extensions}else{$null}
        $v=if($e -is [Collections.IDictionary] -and $e.Contains($Field)){@($e[$Field])}else{@()}
        @($v|Where-Object {[string]$_ -cin $Keys}).Count
    }|ForEach-Object {'task '+$_.id})
}
$like={param([string[]]$Parts) $q=$Query.Trim().ToLowerInvariant();(!$q) -or @($Parts|Where-Object {$_ -and ([string]$_).ToLowerInvariant().Contains($q)}).Count -gt 0}
function Get-FlowUsers($CardId) {
    @($flows|ForEach-Object {$f=$_;foreach($s in $f.steps){if($CardId -in (@($s.ref)+$(if($s.Contains('choices')){@($s.choices)}else{@()}))){'workflow '+$f.key+' (step '+$s.step+')'}}})
}
function ConvertTo-CardItem($p) {
    [ordered]@{kind='prompt';id=$p.id;key=$p.code;title=$p.summary;status=$(if($p.Contains('deprecated')){'deprecated'}else{'active'});revision=$null;area=$p.category;mode=$p.mode;pack=$p.pack;usedBy=@(Get-FlowUsers $p.id)}
}
function ConvertTo-FlowItem($f) {
    [ordered]@{kind='workflow';id=$f.id;key=$f.key;title=$f.title;status=$f.status;revision=$f.revision;area=$(if($f.Contains('pack')){$f.pack}else{'core'});mode=$null;pack=$(if($f.Contains('pack')){$f.pack}else{'core'});usedBy=@(Get-TaskNaming 'workflow' @($f.id,$f.key))}
}
function Get-AgentEntries { @(Read-SBSubagentDefinitions $dossier (Read-SBSubagentCatalog $brain)) }
function ConvertTo-AgentItem($entry,$entries) {
    $d=$entry.definition
    $aid=if($d.Contains('id')){[string]$d.id}else{''}
    $users=@(Get-TaskNaming 'subagents' @($d.name,$aid))
    if($aid){$users+=@($entries|Where-Object {$_.definition.Contains('replacedBy') -and $_.definition.replacedBy -ceq $aid}|ForEach-Object {'agent '+$_.definition.name+' (replacedBy)'})}
    [ordered]@{kind='agent';id=$(if($aid){$aid}else{[string]$d.name});key=[string]$d.name;title=[string]$d.description;status=$(if($d.Contains('status')){[string]$d.status}else{'active'});revision=$(if($d.Contains('revision')){$d.revision}else{$null});area='dossier';mode=$null;pack=$null;usedBy=$users}
}
function Get-Items {
    switch($Kind){
        'prompt' {@($catalog.prompts|Where-Object {& $like @($_.code,$_.summary,$_.id,$_.category)}|ForEach-Object {ConvertTo-CardItem $_})}
        'workflow' {@($flows|Where-Object {& $like @($_.key,$_.title,$_.id)}|ForEach-Object {ConvertTo-FlowItem $_})}
        'agent' {$all=Get-AgentEntries;@($all|Where-Object {& $like @($_.definition.name,$_.definition.description)}|ForEach-Object {ConvertTo-AgentItem $_ $all})}
    }
}
function Find-Item {
    $hit=@(Get-Items|Where-Object {$_.id -ceq $Id -or $_.key -ceq $Id})
    if($hit.Count -ne 1){throw (New-SBError 'library.invalid' @($Kind))}
    $hit[0]
}
if($Operation -eq 'List'){$items=@(Get-Items);ConvertTo-SBJson @{kind=$Kind;items=$items;count=$items.Count};exit 0}
$item=Find-Item
$preview=switch($Kind){
    'prompt' {$card=@($catalog.prompts|Where-Object {$_.id -ceq $item.id})[0];Read-SBText (Resolve-SBParaPath $brain ('directives/prompts/'+$card.file))}
    'workflow' {$f=@($flows|Where-Object {$_.id -ceq $item.id})[0];$byId=@{};foreach($p in $catalog.prompts){$byId[$p.id]=$p};(@($f.steps|ForEach-Object {$n=[array]::IndexOf(@($f.steps),$_)+1;"$n. $($_.step) — $($byId[$_.ref].code) ($($_.kind), gate $($_.gate))"}) -join "`n")}
    'agent' {ConvertTo-SBJson (@(Get-AgentEntries|Where-Object {$_.definition.name -ceq $item.key})[0].definition)}
}
if($Operation -eq 'Show'){ConvertTo-SBJson @{item=$item;preview=$preview;references=@($item.usedBy)};exit 0}
# Retire: the references that would break, plus the plan of the lifecycle command where one exists. Nothing is written.
$blocking=@($item.usedBy)
$plan=$null;$available=$true;$errors=@();$notes=@()
switch($Kind){
    'prompt' {
        $p=Get-SBPromptLifecyclePlan $brain 'retire' @{Code=$item.key}
        $plan=@{valid=$p.valid;changeCount=$p.changeCount;changes=@($p.changes|ForEach-Object {[string]$_[0]+': '+[string]$_[1]})}
        $errors=@($p.errors);$notes=@($p.notes)
        $named=@(Get-TaskNaming 'card' @($item.id,$item.key));if($named.Count){$errors+=@(Get-SBMessage 'library.agent.referenced' @(($named -join ', ')));$blocking+=$named}
    }
    'workflow' {$available=$false;$errors=@(Get-SBMessage 'library.workflow.noretire')}
    'agent' {
        if($blocking.Count){$errors=@(Get-SBMessage 'library.agent.referenced' @(($blocking -join ', ')))}
        if($item.status -ceq 'retired'){$errors+=@('already retired')}
    }
}
$refused=(!$available) -or $errors.Count -gt 0 -or ($plan -and !$plan.valid)
ConvertTo-SBJson @{item=$item;references=@($blocking|Select-Object -Unique);available=$available;refused=$refused;errors=$errors;notes=$notes;plan=$plan;
    command=$(switch($Kind){'prompt'{'scripts/prompt-cards.ps1 -Operation retire -Card '+$item.id+' -Apply'}'agent'{'scripts/subagents.ps1 -Operation Retire -Repository '+$Repository+' -Name '+$item.key+' -Status retired -Apply'}default{$null}})}
