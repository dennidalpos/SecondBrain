#requires -Version 7.5
Set-StrictMode -Version Latest
# Prompt library lifecycle (plan D07): add, edit, duplicate, deprecate and retire cards through validated operations.
# Every operation is planned first (the plan is the preview): the planned files are staged in a temporary copy of the catalog and
# validated with the real loaders, so a plan that validates is a plan that applies. Writing goes through callbacks supplied by the caller.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptMigration.psm1')
Add-SBMessages @{
    'prompts.lifecycle.operation' = @{ en = 'Unknown lifecycle operation: {0}; use add, edit, duplicate, deprecate or retire' }
    'prompts.lifecycle.field' = @{ en = 'Missing or invalid input for {0}: {1}' }
    'prompts.lifecycle.code' = @{ en = 'Code {0} is {1}; codes are never reused, choose a new code' }
    'prompts.lifecycle.body' = @{ en = 'Card body file not found: {0}' }
    'prompts.lifecycle.state' = @{ en = 'Card {0} is already deprecated' }
    'prompts.lifecycle.referenced' = @{ en = 'Cannot retire {0}: referenced by {1}; remove the references or deprecate the card instead' }
    'prompts.lifecycle.validation' = @{ en = 'Catalog validation failed after {0}: {1}' }
    'prompts.lifecycle.refused' = @{ en = 'Lifecycle operation refused: {0}' }
    'prompts.lifecycle.note' = @{ en = 'Note: {0}' }
    'prompts.lifecycle.change' = @{ en = '{0} | {1}' }
    'prompts.lifecycle.summary' = @{ en = 'Lifecycle {0} {1}: {2} file changes; {3}' }
    'prompts.lifecycle.applied' = @{ en = 'Lifecycle {0} applied to {1}: {2} file changes' }
}

$script:SBLifecycleOperations=@('add','edit','duplicate','deprecate','retire')

function Read-SBLifecycleFile([string]$Path,[string]$Label) {
    if(!$Path -or !(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    (Read-SBText $Path).Replace("`r`n","`n")
}

# Card header always follows the catalog summary, so a body supplied without it (or with an old one) is normalized.
function Set-SBLifecycleHeader([string]$Body,[string]$Code,[string]$Summary) {
    $lines=@($Body -split "`n")
    $header='# '+$Code+' — '+$Summary.TrimEnd('.')
    if($lines.Count -and $lines[0].StartsWith('# ')){$lines[0]=$header}else{$lines=@($header,'')+$lines}
    ($lines -join "`n").TrimEnd()+"`n"
}

# Everything that still points at the card: related lists, citations in other cards, workflow steps, the role, deprecation successors.
function Get-SBPromptReferences([string]$BrainRoot,$RawPrompts,$Card,$Workflows) {
    $refs=[Collections.Generic.List[string]]::new()
    $codeById=@{}; foreach($p in $RawPrompts){$codeById[$p.id]=$p.code}
    foreach($p in $RawPrompts){
        if($p.id -eq $Card.id){continue}
        if($p.ContainsKey('related') -and $Card.id -in @($p.related)){$refs.Add('card '+$p.code+' (related)')}
        if($p.ContainsKey('deprecated') -and $p.deprecated.ContainsKey('successor') -and $p.deprecated.successor -eq $Card.id){$refs.Add('card '+$p.code+' (deprecation successor)')}
        foreach($relative in @($p.file,('it/'+$p.file))){
            $path=Join-Path $BrainRoot ('direttive/prompts/'+$relative)
            if((Test-Path -LiteralPath $path -PathType Leaf) -and (Read-SBText $path) -cmatch ('\b'+[regex]::Escape($Card.code)+'\b')){$refs.Add('card '+$p.code+' (text, '+$(if($relative.StartsWith('it/')){'it'}else{'en'})+')')}
        }
    }
    foreach($flow in @($Workflows)){
        foreach($step in $flow.steps){
            $stepRefs=@($step.ref)+$(if($step.ContainsKey('choices')){@($step.choices)}else{@()})
            if($Card.id -in $stepRefs){$refs.Add('workflow '+$flow.key+' (step '+$step.step+')')}
        }
    }
    if($Card.ContainsKey('role')){$refs.Add('role '+$Card.role)}
    @($refs)
}

# Applies the planned files to a temporary copy and validates the copy with the real loaders. Returns $null or the failure message.
function Test-SBPromptLifecycleStage([string]$BrainRoot,$Writes,$Removals) {
    $stage=Join-Path ([IO.Path]::GetTempPath()) ('sb-lifecycle-'+[guid]::NewGuid().ToString('N').Substring(0,12))
    try{
        [IO.Directory]::CreateDirectory((Join-Path $stage 'config'))|Out-Null
        Copy-Item -LiteralPath (Join-Path $BrainRoot 'direttive') -Destination (Join-Path $stage 'direttive') -Recurse
        Copy-Item -Path (Join-Path $BrainRoot 'config/prompt-*.json') -Destination (Join-Path $stage 'config')
        foreach($relative in $Removals){$path=Join-Path $stage $relative; if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
        foreach($relative in $Writes.Keys){
            $path=Join-Path $stage $relative
            [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
            [IO.File]::WriteAllText($path,$Writes[$relative],[Text.UTF8Encoding]::new($false))
        }
        $catalog=Read-SBWorkflowCatalog $stage -ValidateBodies -ValidateReferences
        $flows=@(Read-SBPromptWorkflows $stage $catalog)
        [void](Read-SBPromptAliases $stage $catalog $flows)
        $null
    }catch{$_.Exception.Message}
    finally{if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}}
}

function Get-SBPromptLifecyclePlan([string]$BrainRoot,[string]$Operation,[hashtable]$Options=@{}) {
    $errors=[Collections.Generic.List[string]]::new(); $notes=[Collections.Generic.List[string]]::new()
    $writes=[ordered]@{}; $removals=[Collections.Generic.List[string]]::new(); $changes=[Collections.Generic.List[object]]::new()
    if($Operation -notin $script:SBLifecycleOperations){throw (New-SBError 'prompts.lifecycle.operation' @($Operation))}
    $catalogRelative='direttive/prompts/catalog.json'; $aliasRelative='direttive/prompts/aliases.json'
    $catalog=Read-SBWorkflowCatalog $BrainRoot
    $flows=@(Read-SBPromptWorkflows $BrainRoot $catalog)
    $rawCatalog=ConvertFrom-Json -InputObject (Read-SBText (Join-Path $BrainRoot $catalogRelative)) -AsHashtable
    $aliasPath=Join-Path $BrainRoot $aliasRelative
    $aliasTable=if(Test-Path -LiteralPath $aliasPath -PathType Leaf){ConvertFrom-Json -InputObject (Read-SBText $aliasPath) -AsHashtable}else{[ordered]@{schemaVersion=1;aliases=@()}}
    $aliasCodes=@($aliasTable.aliases|ForEach-Object {$_.code})
    $prompts=[Collections.Generic.List[object]]::new(); foreach($p in $rawCatalog.prompts){$prompts.Add($p)}
    $subject=''; $detail=''
    $requireCode={param($value,$label) if(!$value -or $value -cnotmatch '^[A-Z]{2,4}[0-9]{2}$'){$errors.Add((Get-SBMessage 'prompts.lifecycle.field' @($Operation,$label+' (two to four capitals and two digits)')))}}
    $findRaw={param($key) $resolved=Resolve-SBWorkflowPrompt $catalog $key; $id=$resolved.prompt.id; @($prompts|Where-Object {$_.id -ceq $id})[0]}
    $resolveRelated={param($keys) @(@($keys)|ForEach-Object {(Resolve-SBWorkflowPrompt $catalog $_).prompt.id}|Select-Object -Unique)}
    $replaceCard={param($old,$new) for($i=0;$i -lt $prompts.Count;$i++){if($prompts[$i].id -ceq $old.id){$prompts[$i]=$new}}}
    $withDeprecation={param($card,$deprecated) $copy=[ordered]@{}; foreach($key in $card.Keys){if($key -eq 'deprecated'){continue}; if($key -eq 'i18n' -and $deprecated){$copy.deprecated=$deprecated}; $copy[$key]=$card[$key]}; $copy}
    try{
        switch($Operation){
            'add' {
                $code=$Options['Code']; & $requireCode $code 'Code'
                foreach($required in 'Category','Summary','Target','Mode','Scope','Requires','Example','ItSummary','ItRequires','ItExample'){if(!$Options[$required]){$errors.Add((Get-SBMessage 'prompts.lifecycle.field' @($Operation,$required)))}}
                $body=Read-SBLifecycleFile $Options['BodyPath']; $itBody=Read-SBLifecycleFile $Options['ItBodyPath']
                if($null -eq $body){$errors.Add((Get-SBMessage 'prompts.lifecycle.body' @([string]$Options['BodyPath'])))}
                if($null -eq $itBody){$errors.Add((Get-SBMessage 'prompts.lifecycle.body' @([string]$Options['ItBodyPath'])))}
                if(!$Options['Related']){$errors.Add((Get-SBMessage 'prompts.lifecycle.field' @($Operation,'Related (at least one existing card)')))}
                if($code){
                    if(@($prompts|Where-Object code -ceq $code).Count){$errors.Add((Get-SBMessage 'prompts.lifecycle.code' @($code,'already in the catalog')))}
                    elseif($code -in $aliasCodes){$errors.Add((Get-SBMessage 'prompts.lifecycle.code' @($code,'an alias of an earlier card')))}
                }
                if(!$errors.Count){
                    $id=New-SBWorkflowPromptId $catalog
                    $card=[ordered]@{id=$id;code=$code}
                    if($Options['Role']){$card.role=[string]$Options['Role']}
                    foreach($pair in @(@('category','Category'),@('summary','Summary'),@('target','Target'),@('mode','Mode'),@('scope','Scope'),@('requires','Requires'),@('example','Example'))){$card[$pair[0]]=[string]$Options[$pair[1]]}
                    if($rawCatalog.schemaVersion -ge 2){$card.destructive=[bool]$Options['Destructive'];$card.surface=$(if($Options['Surface']){[string]$Options['Surface']}else{'chat'});$card.pack=$(if($Options['Pack']){[string]$Options['Pack']}else{'core'})}
                    elseif($Options['Destructive']){$card.destructive=$true}
                    $card.file=$code+'.md'
                    $card.related=@(& $resolveRelated $Options['Related'])
                    $card.i18n=[ordered]@{it=[ordered]@{summary=[string]$Options['ItSummary'];requires=[string]$Options['ItRequires'];example=[string]$Options['ItExample']}}
                    $prompts.Add($card)
                    $writes['direttive/prompts/'+$code+'.md']=Set-SBLifecycleHeader $body $code $card.summary
                    $writes['direttive/prompts/it/'+$code+'.md']=Set-SBLifecycleHeader $itBody $code $card.i18n.it.summary
                    $changes.Add(@('add card',$code+' ('+$id+')')); $subject=$code; $detail='new card '+$id
                }
            }
            'edit' {
                $card=& $findRaw $Options['Code']; $code=$card.code; $subject=$code
                $fields=if($Options['Fields']){$Options['Fields']}else{@{}}
                $new=[ordered]@{}; foreach($key in $card.Keys){$new[$key]=$card[$key]}
                $new.i18n=[ordered]@{it=[ordered]@{}}; foreach($key in $card.i18n.it.Keys){$new.i18n.it[$key]=$card.i18n.it[$key]}
                $map=@{category='category';summary='summary';target='target';mode='mode';scope='scope';requires='requires';example='example'}
                foreach($name in $map.Keys){if($fields.ContainsKey($name)){$new[$map[$name]]=[string]$fields[$name]}}
                if($fields.ContainsKey('destructive')){$new.destructive=[bool]$fields.destructive}
                foreach($pair in @(@('itSummary','summary'),@('itRequires','requires'),@('itExample','example'))){if($fields.ContainsKey($pair[0])){$new.i18n.it[$pair[1]]=[string]$fields[$pair[0]]}}
                if($fields.ContainsKey('related')){$new.related=@(& $resolveRelated $fields.related)}
                $body=Read-SBLifecycleFile $Options['BodyPath']; $itBody=Read-SBLifecycleFile $Options['ItBodyPath']
                if($Options['BodyPath'] -and $null -eq $body){$errors.Add((Get-SBMessage 'prompts.lifecycle.body' @([string]$Options['BodyPath'])))}
                if($Options['ItBodyPath'] -and $null -eq $itBody){$errors.Add((Get-SBMessage 'prompts.lifecycle.body' @([string]$Options['ItBodyPath'])))}
                $changedKeys=@($new.Keys|Where-Object {$_ -ne 'i18n' -and (ConvertTo-SBPromptJson $new[$_]) -cne (ConvertTo-SBPromptJson $card[$_])})
                $changedKeys+=@($new.i18n.it.Keys|Where-Object {$new.i18n.it[$_] -cne $card.i18n.it[$_]}|ForEach-Object {'it.'+$_})
                if(!$errors.Count){
                    & $replaceCard $card $new
                    $enText=if($null -ne $body){$body}elseif($new.summary -cne $card.summary){Read-SBLifecycleFile (Join-Path $BrainRoot ('direttive/prompts/'+$card.file))}
                    $itText=if($null -ne $itBody){$itBody}elseif($new.i18n.it.summary -cne $card.i18n.it.summary){Read-SBLifecycleFile (Join-Path $BrainRoot ('direttive/prompts/it/'+$card.file))}
                    if($null -ne $enText){$writes['direttive/prompts/'+$card.file]=Set-SBLifecycleHeader $enText $code $new.summary}
                    if($null -ne $itText){$writes['direttive/prompts/it/'+$card.file]=Set-SBLifecycleHeader $itText $code $new.i18n.it.summary}
                    if($null -ne $body){$changedKeys+='body'}; if($null -ne $itBody){$changedKeys+='it.body'}
                    $changes.Add(@('edit card',$code+': '+$(if($changedKeys.Count){$changedKeys -join ', '}else{'no change'})))
                    $detail=if($changedKeys.Count){'fields '+($changedKeys -join ', ')}else{'nothing to change'}
                }
            }
            'duplicate' {
                $source=& $findRaw $Options['Code']; $code=$Options['NewCode']; & $requireCode $code 'NewCode'; $subject=$code
                if($code){
                    if(@($prompts|Where-Object code -ceq $code).Count){$errors.Add((Get-SBMessage 'prompts.lifecycle.code' @($code,'already in the catalog')))}
                    elseif($code -in $aliasCodes){$errors.Add((Get-SBMessage 'prompts.lifecycle.code' @($code,'an alias of an earlier card')))}
                }
                if(!$errors.Count){
                    $id=New-SBWorkflowPromptId $catalog
                    $copy=[ordered]@{}
                    foreach($key in $source.Keys){
                        if($key -in 'role','deprecated'){continue}
                        $copy[$key]=$source[$key]
                    }
                    $copy.id=$id; $copy.code=$code; $copy.file=$code+'.md'
                    if($Options['Summary']){$copy.summary=[string]$Options['Summary']}
                    $itSummary=if($Options['ItSummary']){[string]$Options['ItSummary']}else{$source.i18n.it.summary}
                    $copy.i18n=[ordered]@{it=[ordered]@{summary=$itSummary;requires=$source.i18n.it.requires;example=$source.i18n.it.example}}
                    $related=@(@($source.id)+@($source.related)|Select-Object -Unique)
                    $copy.related=@($related|Select-Object -First 10)
                    $prompts.Add($copy)
                    $writes['direttive/prompts/'+$code+'.md']=Set-SBLifecycleHeader (Read-SBLifecycleFile (Join-Path $BrainRoot ('direttive/prompts/'+$source.file))) $code $copy.summary
                    $writes['direttive/prompts/it/'+$code+'.md']=Set-SBLifecycleHeader (Read-SBLifecycleFile (Join-Path $BrainRoot ('direttive/prompts/it/'+$source.file))) $code $itSummary
                    $changes.Add(@('duplicate card',$source.code+' -> '+$code+' ('+$id+')')); $detail='copy of '+$source.code+', role not copied'
                }
            }
            'deprecate' {
                $card=& $findRaw $Options['Code']; $code=$card.code; $subject=$code
                if($card.ContainsKey('deprecated')){$errors.Add((Get-SBMessage 'prompts.lifecycle.state' @($code)))}
                if(!$Options['Reason'] -or [string]$Options['Reason'] -notmatch '^[^\r\n\t]+$'){$errors.Add((Get-SBMessage 'prompts.lifecycle.field' @($Operation,'Reason (one line)')))}
                $deprecated=[ordered]@{reason=[string]$Options['Reason']}
                if($Options['Successor']){
                    $successor=& $findRaw $Options['Successor']
                    if($successor.id -ceq $card.id -or $successor.ContainsKey('deprecated')){$errors.Add((Get-SBMessage 'prompts.deprecated.invalid' @($code)))}else{$deprecated.successor=$successor.id}
                }
                if(!$errors.Count){
                    & $replaceCard $card (& $withDeprecation $card $deprecated)
                    $changes.Add(@('deprecate card',$code+': '+$deprecated.reason)); $detail='the card keeps working and warns when selected'
                    foreach($ref in @(Get-SBPromptReferences $BrainRoot $rawCatalog.prompts $card $flows)){$notes.Add($code+' is still used by '+$ref)}
                }
            }
            'retire' {
                $card=& $findRaw $Options['Code']; $code=$card.code; $subject=$code
                $refs=@(Get-SBPromptReferences $BrainRoot $rawCatalog.prompts $card $flows)
                if($refs.Count){$errors.Add((Get-SBMessage 'prompts.lifecycle.referenced' @($code,($refs -join '; '))))}
                else{
                    for($i=$prompts.Count-1;$i -ge 0;$i--){if($prompts[$i].id -ceq $card.id){$prompts.RemoveAt($i)}}
                    $removals.Add('direttive/prompts/'+$card.file); $removals.Add('direttive/prompts/it/'+$card.file)
                    $entries=[ordered]@{}; foreach($entry in $aliasTable.aliases){$entries[$entry.code]=$entry}
                    $entries[$code]=[ordered]@{code=$code;status='retired';retiredId=$card.id}
                    $aliasNew=[ordered]@{schemaVersion=1;aliases=@($entries.Keys|Sort-Object|ForEach-Object {$entries[$_]})}
                    $writes[$aliasRelative]=(ConvertTo-SBPromptJson $aliasNew)+"`n"
                    $changes.Add(@('retire card',$code+' ('+$card.id+'): files removed, alias recorded')); $detail='ID '+$card.id+' retired and never reused'
                }
            }
        }
    }catch{
        if($_.Exception.Data['code']){$errors.Add($_.Exception.Message)}else{throw}
    }
    if(!$errors.Count){
        $rawCatalog.prompts=@($prompts)
        $catalogText=(ConvertTo-SBPromptJson $rawCatalog)+"`n"
        $catalogChanged=((Read-SBText (Join-Path $BrainRoot $catalogRelative)).Replace("`r`n","`n") -cne $catalogText)
        if($catalogChanged){$writes[$catalogRelative]=$catalogText}
    }
    if(!$errors.Count){
        $failure=Test-SBPromptLifecycleStage $BrainRoot $writes @($removals)
        if($failure){$errors.Add((Get-SBMessage 'prompts.lifecycle.validation' @($Operation,$failure)))}
    }
    [pscustomobject]@{
        operation=$Operation;subject=$subject;detail=$detail;valid=($errors.Count -eq 0);errors=@($errors);notes=@($notes)
        changes=@($changes);writes=$writes;removals=@($removals);changeCount=($writes.Count+$removals.Count)
    }
}

function Format-SBPromptLifecyclePlan($Plan) {
    foreach($change in $Plan.changes){Get-SBMessage 'prompts.lifecycle.change' @($change[0],$change[1])}
    foreach($note in $Plan.notes){Get-SBMessage 'prompts.lifecycle.note' @($note)}
    foreach($error in $Plan.errors){Get-SBMessage 'prompts.lifecycle.refused' @($error)}
    if($Plan.valid){Get-SBMessage 'prompts.lifecycle.summary' @($Plan.operation,$Plan.subject,$Plan.changeCount,$Plan.detail)}
}

# Apply order: card files, then removals, then the alias table, then the catalog, which decides what exists.
function Invoke-SBPromptLifecycle([string]$BrainRoot,$Plan,[scriptblock]$Write,[scriptblock]$Remove) {
    if(!$Plan.valid){throw (New-SBError 'prompts.lifecycle.refused' @(($Plan.errors -join '; ')))}
    $catalogKey='direttive/prompts/catalog.json'
    foreach($relative in @($Plan.writes.Keys|Where-Object {$_ -ne $catalogKey})){& $Write (Join-Path $BrainRoot $relative) $Plan.writes[$relative]}
    foreach($relative in $Plan.removals){& $Remove (Join-Path $BrainRoot $relative)}
    if($Plan.writes.Contains($catalogKey)){& $Write (Join-Path $BrainRoot $catalogKey) $Plan.writes[$catalogKey]}
}

Export-ModuleMember -Function @('Get-SBPromptLifecyclePlan','Format-SBPromptLifecyclePlan','Invoke-SBPromptLifecycle','Get-SBPromptReferences')
