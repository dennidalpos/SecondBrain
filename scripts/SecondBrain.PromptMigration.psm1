#requires -Version 7.5
Set-StrictMode -Version Latest
# Prompt library migration (plan P4): applies direttive/prompts/migration-map.json to the catalog. The plan is computed from the current
# state, so it is a preview by itself and a second run finds nothing to change. Writing goes through callbacks supplied by the caller.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Add-SBMessages @{
    'prompts.migration.invalid' = @{ en = 'Invalid prompt migration: {0}; fix direttive/prompts/migration-map.json or the catalog and run migrate-prompts.ps1 again' }
    'prompts.migration.row' = @{ en = '{0} | {1} | {2} | {3}' }
    'prompts.migration.unmapped' = @{ en = 'Not in the migration map (left unchanged, needs an owner decision): {0}' }
    'prompts.migration.deferred' = @{ en = 'Waiting for new cards or workflows (written by later steps): {0} needs {1}' }
    'prompts.migration.summary' = @{ en = 'Migration map: {0} old codes ({1} keep, {2} split, {3} workflow); {4} pending, {5} already migrated; {6} file changes' }
    'prompts.migration.idsummary' = @{ en = 'Old card IDs: {0} kept, {1} retired' }
    'prompts.migration.applied' = @{ en = 'Migration applied: {0} file changes' }
    'prompts.migration.clean' = @{ en = 'Nothing to change: the catalog already follows the migration map' }
}

$script:SBMigrationJson=[Text.Json.JsonSerializerOptions]::new()
$script:SBMigrationJson.Encoder=[Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping

# Serializer in the repository style (2 spaces, LF, expanded arrays, literal non-ASCII); a catalog read and written back is byte-identical.
function ConvertTo-SBPromptJson($Value,[int]$Depth=0) {
    $pad=' '*(2*($Depth+1)); $end=' '*(2*$Depth)
    if($Value -is [Collections.IDictionary]){
        if($Value.Count -eq 0){return '{}'}
        $parts=foreach($key in $Value.Keys){$pad+[Text.Json.JsonSerializer]::Serialize([string]$key,$script:SBMigrationJson)+': '+(ConvertTo-SBPromptJson $Value[$key] ($Depth+1))}
        return "{`n"+($parts -join ",`n")+"`n$end}"
    }
    if($Value -is [Collections.IList]){
        if($Value.Count -eq 0){return '[]'}
        $parts=foreach($item in $Value){$pad+(ConvertTo-SBPromptJson $item ($Depth+1))}
        return "[`n"+($parts -join ",`n")+"`n$end]"
    }
    if($null -eq $Value){return 'null'}
    if($Value -is [bool]){return $Value.ToString().ToLowerInvariant()}
    if($Value -is [string]){return [Text.Json.JsonSerializer]::Serialize($Value,$script:SBMigrationJson)}
    [string]$Value
}

function Read-SBPromptMigrationMap([string]$BrainRoot) {
    $path=Join-Path $BrainRoot 'direttive/prompts/migration-map.json'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw (New-SBError 'prompts.migration.invalid' @('migration-map.json missing'))}
    $map=ConvertFrom-Json -InputObject (Read-SBText $path) -AsHashtable
    if($map.schemaVersion -ne 1 -or !$map.ContainsKey('cards')){throw (New-SBError 'prompts.migration.invalid' @('map schema'))}
    $map
}

function Get-SBPromptMigrationPlan([string]$BrainRoot) {
    $promptDir=Join-Path $BrainRoot 'direttive/prompts'
    $map=Read-SBPromptMigrationMap $BrainRoot
    $catalog=Read-SBWorkflowCatalog $BrainRoot
    $byCode=@{}; foreach($card in $catalog.prompts){$byCode[$card.code]=$card}
    $workflows=@(Read-SBPromptWorkflows $BrainRoot $catalog)
    $flowByKey=@{}; foreach($flow in $workflows){$flowByKey[$flow.key]=$flow}
    $aliasPath=Join-Path $promptDir 'aliases.json'
    $existing=[ordered]@{}
    if(Test-Path -LiteralPath $aliasPath -PathType Leaf){
        $table=ConvertFrom-Json -InputObject (Read-SBText $aliasPath) -AsHashtable
        foreach($entry in $table.aliases){$existing[$entry.code]=$entry}
    }
    $oldCodes=@{}
    foreach($entry in $map.cards){
        if($oldCodes.ContainsKey($entry.oldCode)){throw (New-SBError 'prompts.migration.invalid' @('duplicate '+$entry.oldCode))}
        if($entry.outcome -notin @('keep','split','workflow') -or @($entry.successors).Count -lt 1){throw (New-SBError 'prompts.migration.invalid' @($entry.oldCode))}
        $oldCodes[$entry.oldCode]=$entry
    }
    $rows=@(); $sim=@{}; foreach($code in $byCode.Keys){$sim[$code]=$byCode[$code].id}
    $knownNew=@{}
    foreach($entry in $map.cards){
        $cardSuccessors=@($entry.successors|Where-Object {$_ -notlike 'wf-*'})
        $flowSuccessors=@($entry.successors|Where-Object {$_ -like 'wf-*'})
        if($entry.outcome -eq 'workflow' -and ($cardSuccessors.Count -or !$flowSuccessors.Count)){throw (New-SBError 'prompts.migration.invalid' @($entry.oldCode))}
        if($entry.outcome -ne 'workflow' -and !$cardSuccessors.Count){throw (New-SBError 'prompts.migration.invalid' @($entry.oldCode))}
        foreach($code in $cardSuccessors){
            if($oldCodes.ContainsKey($code)){throw (New-SBError 'prompts.migration.invalid' @('new code collides with an old code: '+$code))}
            $knownNew[$code]=$true
        }
        $newCode=if($cardSuccessors.Count){$cardSuccessors[0]}else{$null}
        $pending=$byCode.ContainsKey($entry.oldCode)
        if($pending){
            $oldId=$byCode[$entry.oldCode].id
            if($newCode -and $byCode.ContainsKey($newCode)){throw (New-SBError 'prompts.migration.invalid' @('both '+$entry.oldCode+' and '+$newCode+' exist'))}
            if($newCode){$sim.Remove($entry.oldCode); $sim[$newCode]=$oldId}else{$sim.Remove($entry.oldCode)}
        }else{
            if(!$existing.Contains($entry.oldCode)){throw (New-SBError 'prompts.migration.invalid' @($entry.oldCode+' is neither in the catalog nor in aliases.json'))}
            $old=$existing[$entry.oldCode]
            $oldId=if($old.ContainsKey('retiredId')){$old.retiredId}elseif($old.ContainsKey('ids')){@($old.ids)[0]}else{$null}
            if($newCode -and !$byCode.ContainsKey($newCode)){throw (New-SBError 'prompts.migration.invalid' @($newCode+' missing for '+$entry.oldCode))}
        }
        $rows+=[pscustomobject]@{
            oldCode=$entry.oldCode;outcome=$entry.outcome;newCode=$newCode;flowKey=$(if($flowSuccessors.Count){$flowSuccessors[0]}else{$null})
            cardSuccessors=$cardSuccessors;flowSuccessors=$flowSuccessors;oldId=$oldId;pending=$pending
            action=$(if($entry.outcome -eq 'workflow'){'retire'}else{'rename'});idFate=$(if($entry.outcome -eq 'workflow'){'retired'}else{'kept'})
            alias=$null;deferred=@()
        }
    }
    # Aliases follow the state the catalog will have: one entry per old code, upgraded only when every successor exists.
    foreach($row in $rows){
        $deferred=@(@($row.cardSuccessors|Where-Object {!$sim.ContainsKey($_)})+@($row.flowSuccessors|Where-Object {!$flowByKey.ContainsKey($_)}))
        $row.deferred=$deferred
        $alias=[ordered]@{code=$row.oldCode}
        if($row.outcome -eq 'workflow'){
            if($flowByKey.ContainsKey($row.flowKey)){$alias.status='workflow';$alias.workflow=$flowByKey[$row.flowKey].id}else{$alias.status='retired'}
            $alias.retiredId=$row.oldId
        }elseif($row.outcome -eq 'split' -and $row.flowSuccessors.Count -eq 0 -and $row.cardSuccessors.Count -ge 2 -and $deferred.Count -eq 0){
            $alias.status='split'; $alias.ids=@($row.cardSuccessors|ForEach-Object {$sim[$_]})
        }else{
            $alias.status='renamed'; $alias.ids=@($sim[$row.newCode])
        }
        $row.alias=$alias
    }
    $unmapped=@($byCode.Keys|Where-Object {!$oldCodes.ContainsKey($_) -and !$knownNew.ContainsKey($_)}|Sort-Object)
    # Final alias table: mapped entries plus any entry the map does not own, sorted by code.
    $entries=[ordered]@{}
    foreach($code in $existing.Keys){if(!$oldCodes.ContainsKey($code)){$entries[$code]=$existing[$code]}}
    foreach($row in $rows){$entries[$row.oldCode]=$row.alias}
    $aliasTable=[ordered]@{schemaVersion=1;aliases=@($entries.Keys|Sort-Object|ForEach-Object {$entries[$_]})}
    $aliasText=(ConvertTo-SBPromptJson $aliasTable)+"`n"
    # Catalog after the migration: renamed cards, retired cards removed, dangling related IDs dropped.
    $retiredIds=@($rows|Where-Object {$_.pending -and $_.action -eq 'retire'}|ForEach-Object oldId)
    $renames=@{}; foreach($row in $rows){if($row.pending -and $row.action -eq 'rename'){$renames[$row.oldCode]=$row.newCode}}
    $newCatalog=ConvertFrom-Json -InputObject (Read-SBText (Join-Path $promptDir 'catalog.json')) -AsHashtable
    $kept=[Collections.Generic.List[object]]::new()
    foreach($card in $newCatalog.prompts){
        if($card.id -in $retiredIds){continue}
        if($renames.ContainsKey($card.code)){$card.code=$renames[$card.code];$card.file=$card.code+'.md'}
        if($card.ContainsKey('related')){$card.related=@($card.related|Where-Object {$_ -notin $retiredIds})}
        $kept.Add($card)
    }
    $newCatalog.prompts=$kept
    $catalogText=(ConvertTo-SBPromptJson $newCatalog)+"`n"
    # File work: moves (en and it), removals of retired cards, and old-code citations rewritten in every surviving card.
    $textMap=@{}
    foreach($row in $rows){$textMap[$row.oldCode]=$(if($row.action -eq 'rename'){$row.newCode}else{$row.flowKey})}
    $moves=@(); $removals=@(); $rewrites=@()
    foreach($row in $rows){
        foreach($lang in @('','it/')){
            $from=Join-Path $promptDir ($lang+$row.oldCode+'.md')
            if($row.action -eq 'rename'){
                $to=Join-Path $promptDir ($lang+$row.newCode+'.md')
                if(Test-Path -LiteralPath $from -PathType Leaf){
                    if(Test-Path -LiteralPath $to){throw (New-SBError 'prompts.migration.invalid' @('target card file exists: '+$lang+$row.newCode+'.md'))}
                    $moves+=[pscustomobject]@{from=$from;to=$to}
                }
            }elseif(Test-Path -LiteralPath $from -PathType Leaf){$removals+=$from}
        }
    }
    $moveFrom=@{}; foreach($move in $moves){$moveFrom[$move.from]=$move.to}
    $removeSet=@{}; foreach($path in $removals){$removeSet[$path]=$true}
    foreach($card in $newCatalog.prompts){
        foreach($lang in @('','it/')){
            $target=Join-Path $promptDir ($lang+$card.code+'.md')
            $source=$target
            foreach($move in $moves){if($move.to -eq $target){$source=$move.from}}
            if(!(Test-Path -LiteralPath $source -PathType Leaf)){continue}
            $text=Read-SBText $source
            $updated=[regex]::Replace($text,'\b[A-Z]{3}\d{2}\b',{param($m) if($textMap.ContainsKey($m.Value)){$textMap[$m.Value]}else{$m.Value}})
            if($updated -cne $text){$rewrites+=[pscustomobject]@{path=$target;text=$updated}}
        }
    }
    $catalogPath=Join-Path $promptDir 'catalog.json'
    $catalogChanged=((Read-SBText $catalogPath) -cne $catalogText)
    $aliasChanged=(!(Test-Path -LiteralPath $aliasPath -PathType Leaf)) -or ((Read-SBText $aliasPath) -cne $aliasText)
    $changeCount=$moves.Count+$removals.Count+$rewrites.Count+[int]$catalogChanged+[int]$aliasChanged
    [pscustomobject]@{
        rows=$rows;unmapped=$unmapped;moves=$moves;removals=$removals;rewrites=$rewrites
        catalogPath=$catalogPath;catalogText=$catalogText;catalogChanged=$catalogChanged
        aliasPath=$aliasPath;aliasText=$aliasText;aliasChanged=$aliasChanged;changeCount=$changeCount
    }
}

function Format-SBPromptMigrationPlan($Plan) {
    foreach($row in $Plan.rows){
        $what=if($row.action -eq 'rename'){'rename to '+$row.newCode}else{'retire into '+$row.flowKey}
        if(!$row.pending){$what+=' (done)'}
        Get-SBMessage 'prompts.migration.row' @($row.oldCode,$row.outcome,$what,$(if($row.idFate -eq 'kept'){'id kept: '+$row.oldId}else{'id retired: '+$row.oldId}))
    }
    foreach($row in @($Plan.rows|Where-Object {$_.deferred.Count})){Get-SBMessage 'prompts.migration.deferred' @($row.oldCode,($row.deferred -join ', '))}
    if($Plan.unmapped.Count){Get-SBMessage 'prompts.migration.unmapped' @($Plan.unmapped -join ', ')}
    $rows=@($Plan.rows)
    Get-SBMessage 'prompts.migration.idsummary' @(@($rows|Where-Object idFate -eq 'kept').Count,@($rows|Where-Object idFate -eq 'retired').Count)
    Get-SBMessage 'prompts.migration.summary' @($rows.Count,@($rows|Where-Object outcome -eq 'keep').Count,@($rows|Where-Object outcome -eq 'split').Count,@($rows|Where-Object outcome -eq 'workflow').Count,@($rows|Where-Object pending).Count,@($rows|Where-Object {!$_.pending}).Count,$Plan.changeCount)
}

# Apply order lets an interrupted run resume: card files first, then the catalog (which decides what is still pending), then the alias table.
function Invoke-SBPromptMigration($Plan,[scriptblock]$Write,[scriptblock]$Move,[scriptblock]$Remove) {
    foreach($item in $Plan.moves){& $Move $item.from $item.to}
    foreach($path in $Plan.removals){& $Remove $path}
    foreach($rewrite in $Plan.rewrites){& $Write $rewrite.path $rewrite.text}
    if($Plan.catalogChanged){& $Write $Plan.catalogPath $Plan.catalogText}
    if($Plan.aliasChanged){& $Write $Plan.aliasPath $Plan.aliasText}
}

Export-ModuleMember -Function @('ConvertTo-SBPromptJson','Read-SBPromptMigrationMap','Get-SBPromptMigrationPlan','Format-SBPromptMigrationPlan','Invoke-SBPromptMigration')
