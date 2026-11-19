#requires -Version 7.5
<#
.SYNOPSIS
User prompts of the Prompts tab (#722): RCTFE prompts of one user, stored outside Git in .runtime/user-prompts/<user>/<id>.json.
.DESCRIPTION
-List shows them, -Preview validates the RCTFE fields and returns the composed prompt with its size, -Create validates and saves, -Delete removes one.
The composed prompt must stay within the 3,500-character budget. System prompts are never written here: they live in the public catalog.
.EXAMPLE
pwsh -NoProfile -File scripts/user-prompts.ps1 -List
.EXAMPLE
pwsh -NoProfile -File scripts/user-prompts.ps1 -Preview -Title 'Review a diff' -Role 'You are a reviewer.' -Context 'Use before a merge.' -Task "1. Read the diff.`n2. Report findings." -Format 'A list of findings.'
#>
[CmdletBinding(DefaultParameterSetName='List')]
param(
    [Parameter(Mandatory,ParameterSetName='List')][switch]$List,
    [Parameter(Mandatory,ParameterSetName='Preview')][switch]$Preview,
    [Parameter(Mandatory,ParameterSetName='Create')][switch]$Create,
    [Parameter(Mandatory,ParameterSetName='Delete')][switch]$Delete,
    [Parameter(Mandatory,ParameterSetName='Delete')][ValidatePattern('^pmt-[0-9a-f]{8}$')][string]$Id,
    [Parameter(Mandatory,ParameterSetName='Preview')][Parameter(Mandatory,ParameterSetName='Create')][string]$Title,
    [Parameter(Mandatory,ParameterSetName='Preview')][Parameter(Mandatory,ParameterSetName='Create')][string]$Role,
    [Parameter(Mandatory,ParameterSetName='Preview')][Parameter(Mandatory,ParameterSetName='Create')][string]$Context,
    [Parameter(Mandatory,ParameterSetName='Preview')][Parameter(Mandatory,ParameterSetName='Create')][string]$Task,
    [Parameter(Mandatory,ParameterSetName='Preview')][Parameter(Mandatory,ParameterSetName='Create')][string]$Format,
    [Parameter(ParameterSetName='Preview')][Parameter(ParameterSetName='Create')][string]$Directive='',
    [string]$ConfigPath,[string]$SessionId
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Access.psm1')
trap { if (Test-SBWriteDeniedError $_) { Write-SBWriteDeniedDiagnostic $_ $PSCommandPath $PSBoundParameters; exit 4 }; if (Test-SBBusyError $_) { [Console]::Error.WriteLine($_.Exception.Message); exit 3 }; break }
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'userprompts.invalid' = @{ en = 'Invalid user prompt: {0}' }
    'userprompts.notfound' = @{ en = 'No user prompt {0}' }
}
$budget=3500
$dash=[string][char]0x2014

function Get-UserPromptRoot($Config) {
    $user=([Environment]::UserName -replace '[^A-Za-z0-9_-]+','-').Trim('-')
    if(!$user){$user='user'}
    Join-Path (Join-Path $Config.brainRoot '.runtime/user-prompts') $user
}

function Get-UserPromptProblems($Fields) {
    $problems=@()
    if(!$Fields.title.Trim()){$problems+='Write a title.'}
    elseif($Fields.title.Trim().Length -gt 120 -or $Fields.title -match '[\r\n]'){$problems+='The title is one line of at most 120 characters.'}
    foreach($pair in @(@('role','Role'),@('context','Context'),@('task','Task'),@('format','Format'))){
        $text=[string]$Fields[$pair[0]]
        if(!$text.Trim()){$problems+=($pair[1]+' is empty.')}
        elseif($text -match '(?m)^\s*</?[a-z_]+>\s*$'){$problems+=($pair[1]+' must not contain section tags.')}
    }
    if(@([regex]::Matches([string]$Fields.task,'(?m)^\d+\. ')).Count -lt 2){$problems+='Task needs at least two numbered steps ("1. ...").'}
    if([string]$Fields.directive -match '(?m)^\s*</?[a-z_]+>\s*$'){$problems+='Directive must not contain section tags.'}
    $problems
}

function ConvertTo-UserPromptText($Fields,[string]$Id) {
    # Same sections and order as a system card (RCTFE); the directive closes the context.
    $context=$Fields.context.Trim()
    if($Fields.directive.Trim()){$context+="`n`nDirective: "+$Fields.directive.Trim()}
    (@(('# '+$Id+' '+$dash+' '+$Fields.title.Trim().TrimEnd('.')),'',
        '<role>',$Fields.role.Trim(),'</role>','',
        '<context>',$context,'</context>','',
        '<task>',$Fields.task.Trim(),'</task>','',
        '<format>',$Fields.format.Trim(),'</format>') -join "`n")+"`n"
}

function New-UserPromptResult($Fields,[string]$Id) {
    $problems=@(Get-UserPromptProblems $Fields)
    $text=ConvertTo-UserPromptText $Fields $Id
    if($text.Length -gt $budget){$problems+=('The composed prompt has '+$text.Length+' characters; the budget is '+$budget+'.')}
    [ordered]@{valid=($problems.Count -eq 0);problems=$problems;characters=$text.Length;budget=$budget;text=$text}
}

$config=Read-SBConfiguration $ConfigPath
$root=Get-UserPromptRoot $config
$fields=[ordered]@{title=$Title;role=$Role;context=$Context;task=$Task;format=$Format;directive=$Directive}
if($List){
    $items=@()
    if([IO.Directory]::Exists($root)){
        foreach($file in @(Get-ChildItem -LiteralPath $root -File -Filter 'pmt-*.json'|Sort-Object Name)){
            $record=Read-SBJson $file.FullName $null
            if($record -is [Collections.IDictionary] -and $record['schema'] -ceq 'secondbrain.user-prompt'){$items+=,$record}
        }
    }
    ConvertTo-SBJson ([ordered]@{schema='secondbrain.user-prompts';schemaVersion=1;budget=$budget;root=$root;prompts=@($items)})
    return
}
if($Preview){
    $result=New-UserPromptResult $fields 'pmt-00000000'
    ConvertTo-SBJson $result
    return
}
$lock=Enter-SBOperation $config $SessionId
try{
    if($Create){
        $id='pmt-'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(4)).ToLowerInvariant()
        $result=New-UserPromptResult $fields $id
        if(!$result.valid){throw (New-SBError 'userprompts.invalid' @($result.problems -join ' '))}
        $record=[ordered]@{schema='secondbrain.user-prompt';schemaVersion=1;id=$id;kind='user';title=$Title.Trim();created=(Get-SBNow).ToUniversalTime().ToString('o')
            fields=$fields;text=$result.text;characters=$result.characters}
        [IO.Directory]::CreateDirectory($root)|Out-Null
        $path=Join-Path $root ($id+'.json')
        Write-SBFile $path ([Text.Encoding]::UTF8.GetBytes((ConvertTo-SBJson $record))) 'absent' $config.backupRoot|Out-Null
        ConvertTo-SBJson $record
    }
    elseif($Delete){
        $path=Join-Path $root ($Id+'.json')
        if(![IO.File]::Exists($path)){throw (New-SBError 'userprompts.notfound' @($Id))}
        [IO.File]::Delete($path)
        ConvertTo-SBJson ([ordered]@{deleted=$Id})
    }
}finally{Exit-SBOperation $lock}
