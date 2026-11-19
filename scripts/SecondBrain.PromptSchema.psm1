#requires -Version 7.5
# RCTFE prompt card schema (#721, first step): Role, Context, Task (plan and numbered steps), Format and constraints, optional Examples.
# Pure functions: they read the legacy eight-section card text and describe it in the new structure; nothing here writes a card or the catalog.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'promptschema.header' = @{ en = 'Card text without a "# CODE - title" header line' }
}

# Legacy tag -> RCTFE section: role -> Role; context and inputs (and the decisions to ask) -> Context; procedure -> Task; constraints, exit criteria and output format -> Format.
function Get-SBLegacyCardTags([string]$Body) {
    $tags=[ordered]@{}
    foreach($m in [regex]::Matches($Body.Replace("`r`n","`n"),'(?ms)^<(?<n>[a-z_]+)>\n(?<t>.*?)\n</\k<n>>[ \t]*$')){$tags[$m.Groups['n'].Value]=$m.Groups['t'].Value.Trim()}
    $tags
}
function ConvertTo-SBRctfeCard([string]$Body,[ValidateSet('system','user')][string]$Kind='user') {
    $text=$Body.Replace("`r`n","`n")
    $header=[regex]::Match($text,'\A# (?<code>[A-Z]{2,4}[0-9]{2}) \u2014 (?<title>[^\n]+)')
    if(!$header.Success){throw (New-SBError 'promptschema.header')}
    $tags=Get-SBLegacyCardTags $text
    $steps=@([regex]::Matches([string]$tags['procedure'],'(?m)^\d+[a-z]?\. (?<s>.+)$')|ForEach-Object {$_.Groups['s'].Value.Trim()})
    $contextParts=@($tags['context'])
    if($tags.Contains('inputs')){$contextParts+="Inputs:`n"+$tags['inputs']}
    if($tags.Contains('decisions')){$contextParts+="Decisions to ask the user:`n"+$tags['decisions']}
    $formatParts=@()
    foreach($name in 'output_format','constraints','exit_criteria'){if($tags.Contains($name)){$formatParts+=$tags[$name]}}
    $title=$header.Groups['title'].Value.Trim().TrimEnd('.')
    [ordered]@{
        schemaVersion=1
        code=$header.Groups['code'].Value
        kind=$Kind
        description=$title
        role=[string]$tags['role']
        context=(($contextParts|Where-Object {$_}) -join "`n`n")
        task=[ordered]@{plan=$title;steps=$steps}
        format=(($formatParts|Where-Object {$_}) -join "`n`n")
    }
}
# Problems of a card against the RCTFE rules; empty when the card is valid. Rules beyond the JSON schema: 3,500-character budget.
function Test-SBRctfeCard($Card,[string]$SchemaFile) {
    $problems=@()
    $json=$Card|ConvertTo-Json -Depth 6
    if($SchemaFile){
        $valid=$false
        try{$valid=[bool](Test-Json -Json $json -SchemaFile $SchemaFile -ErrorAction Stop)}catch{$valid=$false}
        if(!$valid){$problems+='schema'}
    }
    $size=([string]$Card.role).Length+([string]$Card.context).Length+([string]$Card.format).Length+(@($Card.task.steps)|ForEach-Object {([string]$_).Length+3}|Measure-Object -Sum).Sum
    if($size -gt 3500){$problems+="size:$size"}
    if(([string]$Card.description).Length -gt 120){$problems+='description'}
    if(@($Card.task.steps).Count -lt 2){$problems+='steps'}
    $problems
}
Export-ModuleMember -Function ConvertTo-SBRctfeCard,Test-SBRctfeCard,Get-SBLegacyCardTags
