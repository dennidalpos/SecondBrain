#requires -Version 7.5
# Subagent definitions (F8): one versioned JSON format stored as a dossier asset under <dossier>/subagents/<name>.json,
# permissions that can never exceed the parent agent, and per-client export through the adapters of #321.
# Definitions carry no authorization: any write stays behind the parent's reviewed MCP write path (F5).
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.MemoryCycle.psm1')
Add-SBMessages @{
    'subagent.invalid' = @{ en = 'Invalid subagent definition ({0})' }
    'subagent.permission' = @{ en = 'The subagent requests permissions beyond its parent ({0})' }
    'subagent.manage' = @{ en = 'Subagent definition change refused: {0}' }
    'subagent.fallback' = @{ en = 'Client without a verified native format: export the normalized definition; installation grants no permission.' }
}
$script:SBSubagentReadTools=@('get_startup_context','get_ready_tasks','get_task','search_knowledge','list_prompts','get_prompt_home','get_prompt')
$script:SBSubagentWriteTools=@('preview_dossier_write','submit_dossier_write')
$script:SBSubagentSpecialTools=@('check_publication')
$script:SBSubagentFields=@('schemaVersion','name','description','role','context','permissions')
# Schema 2 (docs/reference/asset-contracts.md section 4): identity, revisioning, composable cards, output contract and delegation bounds.
$script:SBSubagentFields2=@('schemaVersion','id','name','revision','status','description','role','context','permissions','cards','output','bounds','replacedBy','model')
$script:SBSubagentOptional2=@('cards','replacedBy','model')
$script:SBSubagentProviders=@('any','claude','codex','gemini')
$script:SBSubagentPermissionFields=@('tools','write')
$script:SBSubagentStatuses=@('draft','active','deprecated','retired')
$script:SBSubagentOutputKinds=@('text','report','object')
$script:SBSubagentModeRank=@{read=0;verify=1;write=2}

function Get-SBSubagentTools { @{read=$script:SBSubagentReadTools;write=$script:SBSubagentWriteTools;special=$script:SBSubagentSpecialTools} }

function Get-SBSubagentDirectory([string]$Dossier) { Join-Path $Dossier 'subagents' }

function Test-SBSubagentInteger($Value,[long]$Min,[long]$Max) { ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Min -and $Value -le $Max }

# Highest card mode a delegate may compose: without write permission only read cards (verify cards write reports).
function Get-SBSubagentMaxMode($Definition) { if($Definition.permissions.write){'write'}else{'read'} }

function Test-SBSubagentDefinition($Definition) {
    $fail={param($why) throw (New-SBError 'subagent.invalid' @($why))}
    if($Definition -isnot [Collections.IDictionary]){& $fail 'definition'}
    if(!$Definition.Contains('schemaVersion') -or !(Test-SBSubagentInteger $Definition.schemaVersion 1 2)){& $fail 'schemaVersion'}
    $schema=[int]$Definition.schemaVersion
    $fields=if($schema -eq 1){$script:SBSubagentFields}else{$script:SBSubagentFields2}
    $required=if($schema -eq 1){$script:SBSubagentFields}else{@($script:SBSubagentFields2|Where-Object {$_ -cnotin $script:SBSubagentOptional2})}
    foreach($key in $Definition.Keys){if($key -cnotin $fields){& $fail ('field '+$key)}}
    foreach($key in $required){if(!$Definition.Contains($key)){& $fail ('missing '+$key)}}
    if($Definition.name -isnot [string] -or $Definition.name -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$'){& $fail 'name'}
    foreach($key in 'description','role','context'){
        if($Definition[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Definition[$key]) -or $Definition[$key].Length -gt 8192){& $fail $key}
    }
    $perm=$Definition.permissions
    if($perm -isnot [Collections.IDictionary]){& $fail 'permissions'}
    foreach($key in $perm.Keys){if($key -cnotin $script:SBSubagentPermissionFields){& $fail ('permissions.'+$key)}}
    foreach($key in $script:SBSubagentPermissionFields){if(!$perm.Contains($key)){& $fail ('permissions missing '+$key)}}
    if($perm.write -isnot [bool]){& $fail 'permissions.write'}
    if($perm.tools -isnot [Collections.IEnumerable] -or $perm.tools -is [string]){& $fail 'permissions.tools'}
    $known=$script:SBSubagentReadTools+$script:SBSubagentWriteTools+$script:SBSubagentSpecialTools
    $seen=@{}
    foreach($tool in @($perm.tools)){
        if($tool -isnot [string] -or $tool -cnotin $known){& $fail 'permissions.tools entry'}
        if($seen.ContainsKey($tool)){& $fail 'permissions.tools duplicate'}
        $seen[$tool]=$true
        if($tool -cin $script:SBSubagentWriteTools -and !$perm.write){& $fail 'write tool without write=true'}
    }
    if($schema -eq 2){
        if($Definition.id -isnot [string] -or $Definition.id -cnotmatch '^agt-[0-9a-f]{8}$'){& $fail 'id'}
        if(!(Test-SBSubagentInteger $Definition.revision 1 ([int]::MaxValue))){& $fail 'revision'}
        if($Definition.status -isnot [string] -or $Definition.status -cnotin $script:SBSubagentStatuses){& $fail 'status'}
        if($Definition.Contains('replacedBy')){
            if($Definition.replacedBy -isnot [string] -or $Definition.replacedBy -cnotmatch '^agt-[0-9a-f]{8}$' -or $Definition.replacedBy -ceq $Definition.id){& $fail 'replacedBy'}
            if($Definition.status -cnotin @('deprecated','retired')){& $fail 'replacedBy without deprecated or retired status'}
        }
        if($Definition.Contains('cards')){
            if($Definition.cards -isnot [Collections.IEnumerable] -or $Definition.cards -is [string] -or $Definition.cards -is [Collections.IDictionary]){& $fail 'cards'}
            $refs=@{}
            foreach($ref in @($Definition.cards)){
                if($ref -isnot [string] -or ($ref -cnotmatch '^pmt-[0-9a-f]{8}$' -and $ref -cnotmatch '^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)*$')){& $fail 'cards entry'}
                if($refs.ContainsKey($ref)){& $fail 'cards duplicate'}
                $refs[$ref]=$true
            }
        }
        if($Definition.Contains('model')){
            $model=$Definition.model
            if($model -isnot [Collections.IDictionary]){& $fail 'model'}
            foreach($key in $model.Keys){if($key -cnotin @('provider','name')){& $fail ('model.'+$key)}}
            if($model.provider -isnot [string] -or $model.provider -cnotin $script:SBSubagentProviders){& $fail 'model.provider'}
            if($model.Contains('name') -and ($model.name -isnot [string] -or $model.name -cnotmatch '^[A-Za-z0-9._:/@\[\]-]{1,120}$' -or $model.provider -ceq 'any')){& $fail 'model.name'}
        }
        $out=$Definition.output
        if($out -isnot [Collections.IDictionary]){& $fail 'output'}
        foreach($key in $out.Keys){if($key -cnotin @('kind','schema')){& $fail ('output.'+$key)}}
        if($out.kind -isnot [string] -or $out.kind -cnotin $script:SBSubagentOutputKinds){& $fail 'output.kind'}
        if($out.Contains('schema') -and ($out.schema -isnot [string] -or $out.schema -cnotmatch '^config/[A-Za-z0-9._/-]+\.json$' -or $out.schema.Contains('..'))){& $fail 'output.schema'}
        if($out.kind -ceq 'object' -and !$out.Contains('schema')){& $fail 'output.schema required for object'}
        $bounds=$Definition.bounds
        if($bounds -isnot [Collections.IDictionary]){& $fail 'bounds'}
        foreach($key in $bounds.Keys){if($key -cnotin @('depth','budget')){& $fail ('bounds.'+$key)}}
        if(!$bounds.Contains('depth') -or !(Test-SBSubagentInteger $bounds.depth 1 1)){& $fail 'bounds.depth'}
        $budget=if($bounds.Contains('budget')){$bounds.budget}else{$null}
        if($budget -isnot [Collections.IDictionary] -or !$budget.Count){& $fail 'bounds.budget'}
        foreach($key in $budget.Keys){if($key -cnotin @('turns','minutes')){& $fail ('bounds.budget.'+$key)}}
        if($budget.Contains('turns') -and !(Test-SBSubagentInteger $budget.turns 1 1000)){& $fail 'bounds.budget.turns'}
        if($budget.Contains('minutes') -and !(Test-SBSubagentInteger $budget.minutes 1 1440)){& $fail 'bounds.budget.minutes'}
    }
    $true
}

# Card references resolve against the public catalog (directives/prompts/catalog.json): by pmt- ID, or by role on exactly one active card.
# Draft and retired cards are not composable; a card above the definition's effective mode is an error.
function Resolve-SBSubagentCards($Definition,$Catalog) {
    $fail={param($why) throw (New-SBError 'subagent.invalid' @($why))}
    if([int]$Definition.schemaVersion -ne 2 -or !$Definition.Contains('cards')){return ,@()}
    $refs=@($Definition.cards)
    if(!$refs.Count){return ,@()}
    if($Catalog -isnot [Collections.IDictionary] -or !$Catalog.Contains('prompts')){& $fail 'cards without catalog'}
    $maxMode=Get-SBSubagentMaxMode $Definition
    $resolved=@()
    foreach($ref in $refs){
        $byId=$ref.StartsWith('pmt-')
        $found=@($Catalog.prompts|Where-Object {$_ -is [Collections.IDictionary] -and $(if($byId){$_.id -ceq $ref}else{$_.Contains('role') -and $_.role -ceq $ref -and (!$_.Contains('status') -or $_.status -ceq 'active')})})
        if($found.Count -ne 1){& $fail ('card unresolved '+$ref)}
        $card=$found[0]
        $status=if($card.Contains('status')){[string]$card.status}else{'active'}
        if($status -cnotin @('active','deprecated')){& $fail ('card not composable '+$ref)}
        if($card.mode -isnot [string] -or !$script:SBSubagentModeRank.ContainsKey($card.mode)){& $fail ('card mode '+$ref)}
        if($script:SBSubagentModeRank[$card.mode] -gt $script:SBSubagentModeRank[$maxMode]){& $fail ('card '+$ref+' mode '+$card.mode+' above '+$maxMode)}
        $resolved+=,([ordered]@{ref=$ref;id=$card.id;code=$card.code;mode=$card.mode;status=$status})
    }
    ,$resolved
}

function Read-SBSubagentCatalog([string]$BrainRoot) {
    $path=Join-Path $BrainRoot 'directives/prompts/catalog.json'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    (Read-SBText $path)|ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Read-SBSubagentDefinitions([string]$Dossier,$Catalog) {
    $directory=Get-SBSubagentDirectory $Dossier
    $items=@()
    if(!(Test-Path -LiteralPath $directory -PathType Container)){return $items}
    Assert-SBPlainPath $directory
    foreach($file in Get-ChildItem -LiteralPath $directory -File -Force|Sort-Object Name){
        if($file.Extension -cne '.json'){throw (New-SBError 'subagent.invalid' @('file '+$file.Name))}
        Assert-SBPlainPath $file.FullName
        try{$definition=(Read-SBText $file.FullName)|ConvertFrom-Json -AsHashtable -ErrorAction Stop}catch{throw (New-SBError 'subagent.invalid' @('json '+$file.Name))}
        [void](Test-SBSubagentDefinition $definition)
        if($file.BaseName -cne $definition.name){throw (New-SBError 'subagent.invalid' @('name differs from file '+$file.Name))}
        if($definition.Contains('id') -and @($items|Where-Object {$_.definition.Contains('id') -and $_.definition.id -ceq $definition.id}).Count){throw (New-SBError 'subagent.invalid' @('duplicate id '+$definition.id))}
        $cards=Resolve-SBSubagentCards $definition $Catalog
        $items+=,@{definition=$definition;cards=$cards;path=$file.FullName;sha256=(Get-SBFileHash $file.FullName)}
    }
    $items
}

# Lifecycle, output and delegation bounds as Resolve reports them; schema 1 has the fixed depth 1 and no declared budget.
function Get-SBSubagentSummary($Definition) {
    if([int]$Definition.schemaVersion -eq 2){
        $budget=[ordered]@{};foreach($key in @($Definition.bounds.budget.Keys|Sort-Object)){$budget[$key]=$Definition.bounds.budget[$key]}
        return [ordered]@{schemaVersion=2;id=$Definition.id;revision=$Definition.revision;status=$Definition.status;replacedBy=$(if($Definition.Contains('replacedBy')){$Definition.replacedBy}else{$null});
            output=[ordered]@{kind=$Definition.output.kind;schema=$(if($Definition.output.Contains('schema')){$Definition.output.schema}else{$null})};
            bounds=[ordered]@{depth=1;budget=$budget};maxCardMode=(Get-SBSubagentMaxMode $Definition)}
    }
    [ordered]@{schemaVersion=1;id=$null;revision=$null;status='active';replacedBy=$null;output=$null;bounds=[ordered]@{depth=1;budget=$null};maxCardMode=(Get-SBSubagentMaxMode $Definition)}
}

# Reports of the Validate and Resolve operations over entries from Read-SBSubagentDefinitions.
function Get-SBSubagentValidateReport($Entries) {
    @{state='valid';definitions=@(@($Entries)|Where-Object {$null -ne $_}|ForEach-Object {@{name=$_.definition.name;schemaVersion=$_.definition.schemaVersion;id=$(if($_.definition.Contains('id')){$_.definition.id}else{$null});sha256=$_.sha256;cards=@($_.cards)}})}
}

function Get-SBSubagentResolveReport($Entries,$Parent) {
    @{parent=$Parent;agents=@(@($Entries)|Where-Object {$null -ne $_}|ForEach-Object {
        $agent=Resolve-SBSubagentPermissions $_.definition $Parent
        $summary=Get-SBSubagentSummary $_.definition
        foreach($key in $summary.Keys){$agent[$key]=$summary[$key]}
        $agent.cards=@($_.cards)
        $agent})}
}

# Effective permissions are the intersection with the parent; requesting anything the parent lacks is an error, never silently trimmed.
function Resolve-SBSubagentPermissions($Definition,$Parent) {
    [void](Test-SBSubagentDefinition $Definition)
    if($Parent -isnot [Collections.IDictionary] -or !$Parent.Contains('tools') -or !$Parent.Contains('write') -or $Parent.write -isnot [bool]){throw (New-SBError 'subagent.invalid' @('parent'))}
    $parentTools=@($Parent.tools)
    foreach($tool in @($Definition.permissions.tools)){
        if($tool -cnotin $parentTools){throw (New-SBError 'subagent.permission' @($tool))}
    }
    if($Definition.permissions.write -and !$Parent.write){throw (New-SBError 'subagent.permission' @('write'))}
    $writeAllowed=$Definition.permissions.write -and $Parent.write
    @{name=$Definition.name;tools=@($Definition.permissions.tools|Sort-Object);write=$writeAllowed;
      writeAuthorization='parent-reviewed-mcp-write';inherited=$true}
}

# Native client formats (sources: docs/reference/source-provenance-3-0.md, checked 2026-11-16). Every definition field a client cannot
# represent is listed under `unsupported` instead of being dropped silently; `enforcement` separates what the client itself enforces
# (a tool allowlist) from what is only declared (text the model may ignore, or a restriction the parent session owns).
$script:SBSubagentNativeClients=@{
    'claude-code'=@{provider='claude';format='claude-code-markdown';path='.claude/agents/{0}.md'}
    'codex'=@{provider='codex';format='codex-toml';path='.codex/agents/{0}.toml'}
    'gemini'=@{provider='gemini';format='gemini-markdown';path='.gemini/agents/{0}.md'}
}
function Get-SBSubagentNativeClients { ,@($script:SBSubagentNativeClients.Keys|Sort-Object) }
function ConvertTo-SBNativeString([string]$Text) { (ConvertTo-Json ([string]$Text) -Compress) }

function ConvertTo-SBSubagentExport($Definition,$Permissions,[string]$Client) {
    $native=$script:SBSubagentNativeClients[$Client]
    $adapter=if($Client -ne 'gemini'){Get-SBCycleAdapter $Client}else{$null}
    $tools=@($Permissions.tools)
    $normalized=[ordered]@{schemaVersion=1;name=$Definition.name;description=$Definition.description;role=$Definition.role;context=$Definition.context;
        permissions=[ordered]@{tools=$tools;write=[bool]$Permissions.write;writeAuthorization=$Permissions.writeAuthorization}}
    $v2=[int]$Definition.schemaVersion -eq 2
    $summary=$null
    if($v2){
        $summary=Get-SBSubagentSummary $Definition
        $normalized=[ordered]@{schemaVersion=2;id=$Definition.id;name=$Definition.name;revision=$Definition.revision;status=$Definition.status;description=$Definition.description;role=$Definition.role;context=$Definition.context;
            permissions=$normalized.permissions;cards=@(if($Definition.Contains('cards')){$Definition.cards});output=$summary.output;bounds=$summary.bounds}
    }
    if(!$native){
        return @{client=$Client;format='normalized-json';relativePath=('subagents/'+$Definition.name+'.'+$Client+'.json');content=(ConvertTo-SBJson $normalized);liveVerified=$false;note=(Get-SBMessage 'subagent.fallback');unsupported=@();enforcement=$null}
    }
    $oneLine=($Definition.description -replace '\s+',' ').Trim()
    $text=$Definition.role.Trim()+"`n`n"+$Definition.context.Trim()+"`n"
    $unsupported=@()
    $hasModel=$Definition.Contains('model') -and $Definition.model -and $Definition.model.Contains('name') -and $Definition.model.name
    $modelName=if($hasModel -and $Definition.model.provider -ceq $native.provider){[string]$Definition.model.name}else{$null}
    if($hasModel -and !$modelName){$unsupported+=,@{field='model';reason=('preference for provider '+$Definition.model.provider+' does not apply to '+$Client)}}
    $metadata=@('id','revision','status','cards','output','bounds')
    switch($Client){
        'claude-code' {
            $mcpTools=@($tools|ForEach-Object {'mcp__secondbrain__'+$_}) -join ', '
            $content="---`nname: "+$Definition.name+"`ndescription: "+(ConvertTo-SBNativeString $oneLine)+"`ntools: "+$mcpTools+"`n"
            if($modelName){$content+="model: "+(ConvertTo-SBNativeString $modelName)+"`n"}
            $content+="---`n`n"+$text
            if($v2){foreach($f in $metadata){$unsupported+=,@{field=$f;reason='no frontmatter field in the Claude Code subagent format'}}}
            $enforced=@('tools');$declared=@('write')
        }
        'codex' {
            # The TOML file inherits the parent's permissions, provider and MCP servers and cannot override them: nothing is enforceable here.
            $permissionText='Allowed SecondBrain MCP tools: '+($tools -join ', ')+'. Write access: '+$(if($Permissions.write){'only through the reviewed MCP write path'}else{'none'})+'.'
            $content="name = "+(ConvertTo-SBNativeString $Definition.name)+"`ndescription = "+(ConvertTo-SBNativeString $oneLine)+"`n"
            if($modelName){$content+="model = "+(ConvertTo-SBNativeString $modelName)+"`n"}
            $content+="developer_instructions = "+(ConvertTo-SBNativeString ($text.TrimEnd("`n")+"`n`n"+$permissionText))+"`n"
            $unsupported+=,@{field='permissions.tools';reason='Codex custom agents inherit the parent session and have no per-tool allowlist; the allowed tools are declared in the instructions only'}
            $unsupported+=,@{field='permissions.write';reason='sandbox and write access are inherited from the parent session and cannot be overridden by the agent file'}
            if($v2){foreach($f in $metadata){$unsupported+=,@{field=$f;reason='no field in the Codex custom agent TOML'}}}
            $enforced=@();$declared=@('tools','write')
        }
        'gemini' {
            # Gemini CLI loads agents only with experimental.enableAgents; MCP tools are addressed as mcp_<server>_<tool>.
            $content="---`nname: "+$Definition.name+"`ndescription: "+(ConvertTo-SBNativeString $oneLine)+"`nkind: local`ntools:`n"
            foreach($tool in $tools){$content+="  - mcp_secondbrain_"+$tool+"`n"}
            if($modelName){$content+="model: "+(ConvertTo-SBNativeString $modelName)+"`n"}
            $budget=if($v2){$summary.bounds.budget}else{$null}
            if($budget -and $budget.Contains('turns')){$content+="max_turns: "+[int]$budget.turns+"`n"}
            if($budget -and $budget.Contains('minutes')){$content+="timeout_mins: "+[int]$budget.minutes+"`n"}
            $content+="---`n`n"+$text
            if($tools.Count -eq 0){$unsupported+=,@{field='permissions.tools';reason='an empty tool list means all tools in Gemini CLI; the agent would not be restricted'}}
            if($v2){foreach($f in @('id','revision','status','cards','output')){$unsupported+=,@{field=$f;reason='no frontmatter field in the Gemini CLI subagent format'}}}
            $enforced=@('tools');$declared=@('write')
        }
    }
    $enforcement=[ordered]@{enforcedByClient=@($enforced);declaredOnly=@($declared);tools=$(if($enforced.Count){'client-allowlist'}else{'declared'});
        write=$(if($Client -ceq 'codex'){'declared'}elseif($Permissions.write){'declared-reviewed-mcp-write-path'}else{'no-write-tool-in-allowlist'})}
    @{client=$Client;format=$native.format;relativePath=($native.path -f $Definition.name);content=$content.Replace("`r`n","`n");liveVerified=$(if($adapter){$adapter.liveVerified}else{$false});note=$null;unsupported=@($unsupported);enforcement=$enforcement}
}

# Export to a package folder (never into a checkout): preview by default, apply writes verified files.
# Draft and retired definitions are not runnable (asset-contracts section 1.3) and stay out of the export.
function Export-SBSubagents([string]$Dossier,[string]$Client,$Parent,[string]$OutputRoot,[string]$BackupRoot,[switch]$Apply,$Catalog,$Capabilities) {
    # $Capabilities: optional output of Get-SBAgentCapabilities for the client's provider; the report then says whether the CLI is installed.
    $probe=$null
    $nativeClient=$script:SBSubagentNativeClients[$Client]
    if($Capabilities -and $nativeClient){
        $probe=[ordered]@{provider=$nativeClient.provider;installed=[bool]$Capabilities.installed;status=$Capabilities.status;version=$Capabilities.version}
    }
    $all=@(Read-SBSubagentDefinitions $Dossier $Catalog)
    $runnable={param($e) !$e.definition.Contains('status') -or $e.definition.status -cin @('active','deprecated')}
    $entries=@($all|Where-Object {& $runnable $_})
    $skipped=@($all|Where-Object {!(& $runnable $_)}|ForEach-Object {@{name=$_.definition.name;status=$_.definition.status}})
    $files=@()
    foreach($entry in $entries){
        $permissions=Resolve-SBSubagentPermissions $entry.definition $Parent
        $export=ConvertTo-SBSubagentExport $entry.definition $permissions $Client
        $files+=,@{name=$entry.definition.name;relativePath=$export.relativePath;format=$export.format;sourceSha256=$entry.sha256;contentSha256=(Get-SBTextHash $export.content);content=$export.content;liveVerified=$export.liveVerified;note=$export.note;unsupported=@($export.unsupported);enforcement=$export.enforcement}
    }
    $root=[IO.Path]::GetFullPath($OutputRoot)
    $changed=@()
    foreach($file in $files){
        $target=[IO.Path]::GetFullPath((Join-Path $root $file.relativePath))
        if(!$target.StartsWith($root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw (New-SBError 'subagent.invalid' @('output scope'))}
        Assert-SBPlainPath $target
        $current=Get-SBFileHash $target
        if($current -ne (Get-SBHash ([Text.UTF8Encoding]::new($false).GetBytes($file.content)))){$changed+=,@{file=$file;target=$target;current=$current}}
    }
    if($Apply){
        foreach($item in $changed){
            [void][IO.Directory]::CreateDirectory((Split-Path $item.target))
            [void](Write-SBFile $item.target ([Text.UTF8Encoding]::new($false).GetBytes($item.file.content)) $item.current $BackupRoot)
        }
    }
    @{state=$(if(!$changed.Count){'unchanged'}elseif($Apply){'applied'}else{'preview'});client=$Client;count=$files.Count;changed=@($changed|ForEach-Object {$_.file.relativePath});skipped=$skipped;
      files=@($files|ForEach-Object {@{name=$_.name;relativePath=$_.relativePath;format=$_.format;sourceSha256=$_.sourceSha256;contentSha256=$_.contentSha256;liveVerified=$_.liveVerified;unsupported=@($_.unsupported);enforcement=$_.enforcement}});probe=$probe}
}

# Register record of a subagent job: always references the parent session (validated by the register against the log).
function New-SBSubagentActivityRecord([string]$Repository,[string]$User,[string]$Computer,[string]$TaskId,[string]$ParentSession,[string]$Agent,[string]$Session,[string]$When,[string]$Outcome,[string]$Detail,[string]$Where='subagent') {
    $key=$Repository+"`n"+$ParentSession+"`n"+$Agent+"`n"+$Session+"`n"+$When+"`n"+$Outcome
    @{schemaVersion=1;eventId=(Get-SBTextHash $key).Substring(0,32).ToLowerInvariant();user=$User;repository=$Repository;taskId=$TaskId;session=$Session;when=$When;where=$Where;computer=$Computer;outcome=$Outcome;detail=$Detail;parent=$ParentSession;agent=$Agent}
}
# Management operations (#622): Create, Edit, Revise and Retire schema 2 definitions with the validation of Test-SBSubagentDefinition.
# They only build a plan (before, after, bytes, expected hash); Save-SBSubagentManagePlan writes it with a verified backup. A definition never grants authorization.
$script:SBSubagentManageEditable=@('description','context')
function ConvertTo-SBSubagentPlain($Value) { (ConvertTo-SBJson $Value)|ConvertFrom-Json -AsHashtable }
function New-SBSubagentId([object[]]$Entries) {
    $taken=@($Entries|Where-Object {$_.definition.Contains('id')}|ForEach-Object {$_.definition.id})
    do{$id='agt-'+((New-SBId) -replace '[^0-9a-f]','').PadRight(8,'0').Substring(0,8)}while($id -in $taken)
    $id
}
function Test-SBSubagentWidened($Old,$New) {
    # Compatible changes only narrow or keep permissions and keep the output contract; anything else needs a new ID (asset contracts 1.2).
    if($New.permissions.write -and !$Old.permissions.write){return 'write permission widened'}
    foreach($tool in @($New.permissions.tools)){if($tool -cnotin @($Old.permissions.tools)){return ('tool added: '+$tool)}}
    if((ConvertTo-SBJson $New.output) -cne (ConvertTo-SBJson $Old.output)){return 'output contract changed'}
    $null
}
function Get-SBSubagentManagePlan {
    param([Parameter(Mandatory)][string]$Dossier,$Catalog,[Parameter(Mandatory)][ValidateSet('Create','Edit','Revise','Retire')][string]$Action,
        $Definition,[string]$Name,[string]$Status,[string]$ReplacedBy)
    $refuse={param($why) throw (New-SBError 'subagent.manage' @($why))}
    $entries=@(Read-SBSubagentDefinitions $Dossier $Catalog)
    $directory=Get-SBSubagentDirectory $Dossier
    $current=$null
    if($Action -ne 'Create'){
        if(!$Name){& $refuse 'name required'}
        $current=@($entries|Where-Object {$_.definition.name -ceq $Name})
        if($current.Count -ne 1){& $refuse ('unknown definition '+$Name)}
        $current=$current[0]
        if([int]$current.definition.schemaVersion -ne 2){& $refuse 'schema 1 definitions are migrated by creating a schema 2 definition'}
    }
    $after=$null
    switch($Action){
        'Create' {
            if($Definition -isnot [Collections.IDictionary]){& $refuse 'definition required'}
            $after=ConvertTo-SBSubagentPlain $Definition
            $after.schemaVersion=2
            if(!$after.Contains('revision')){$after.revision=1}elseif($after.revision -ne 1){& $refuse 'a new definition starts at revision 1'}
            if(!$after.Contains('status')){$after.status='draft'}elseif($after.status -cnotin @('draft','active')){& $refuse 'a new definition is draft or active'}
            if($after.Contains('id') -and ($after.id -in @($entries|Where-Object {$_.definition.Contains('id')}|ForEach-Object {$_.definition.id}))){& $refuse 'id already used'}
            if(!$after.Contains('id')){$after.id=New-SBSubagentId $entries}
            if(@($entries|Where-Object {$_.definition.name -ceq $after.name}).Count){& $refuse ('definition exists: '+$after.name)}
        }
        'Edit' {
            if($Definition -isnot [Collections.IDictionary]){& $refuse 'definition required'}
            $after=ConvertTo-SBSubagentPlain $current.definition
            $incoming=ConvertTo-SBSubagentPlain $Definition
            foreach($key in $incoming.Keys){
                if($key -cnotin $script:SBSubagentManageEditable){
                    if((ConvertTo-SBJson $incoming[$key]) -cne (ConvertTo-SBJson $after[$key])){& $refuse ('Edit changes only '+($script:SBSubagentManageEditable -join ' and ')+' (wording); '+$key+' is a contract field: use Revise')}
                    continue
                }
                $after[$key]=$incoming[$key]
            }
            if((ConvertTo-SBJson $after) -ceq (ConvertTo-SBJson $current.definition)){& $refuse 'nothing changed'}
        }
        'Revise' {
            if($Definition -isnot [Collections.IDictionary]){& $refuse 'definition required'}
            $after=ConvertTo-SBSubagentPlain $Definition
            $old=$current.definition
            foreach($key in 'id','name','status'){
                if(!$after.Contains($key)){$after[$key]=$old[$key]}elseif($after[$key] -cne $old[$key]){& $refuse ($key+' cannot change in a revision')}
            }
            if($after.Contains('replacedBy') -and !$old.Contains('replacedBy')){& $refuse 'use Retire to set replacedBy'}
            $after.schemaVersion=2
            if(!$after.Contains('revision') -or $after.revision -eq $old.revision){$after.revision=[int]$old.revision+1}elseif($after.revision -ne ([int]$old.revision+1)){& $refuse ('the next revision is '+([int]$old.revision+1))}
            $widened=Test-SBSubagentWidened $old $after
            if($widened){& $refuse ('breaking change ('+$widened+'): create a new definition and retire this one with replacedBy')}
            if((ConvertTo-SBJson $after) -ceq (ConvertTo-SBJson $old)){& $refuse 'nothing changed'}
        }
        'Retire' {
            $order=@('draft','active','deprecated','retired')
            if($Status -cnotin @('deprecated','retired')){& $refuse 'Status must be deprecated or retired'}
            $old=$current.definition
            if($order.IndexOf($Status) -le $order.IndexOf([string]$old.status)){& $refuse ('transitions only go forward: '+$old.status+' -> '+$Status+' is not allowed')}
            $after=ConvertTo-SBSubagentPlain $old
            $after.status=$Status
            if($ReplacedBy){
                if($ReplacedBy -cnotmatch '^agt-[0-9a-f]{8}$' -or $ReplacedBy -ceq $old.id){& $refuse 'replacedBy'}
                if(!@($entries|Where-Object {$_.definition.Contains('id') -and $_.definition.id -ceq $ReplacedBy -and $_.definition.status -cin @('active','draft')}).Count){& $refuse 'replacedBy must name an existing active or draft definition'}
                $after.replacedBy=$ReplacedBy
            }
        }
    }
    [void](Test-SBSubagentDefinition $after)
    [void](Resolve-SBSubagentCards $after $Catalog)
    $path=Join-Path $directory ($after.name+'.json')
    $before=if($current){$current.definition}else{$null}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-SBJson $after))
    @{action=$Action;name=$after.name;id=$after.id;revision=$after.revision;status=$after.status;path=$path;before=$before;after=$after;bytes=$bytes;expected=(Get-SBFileHash $path)}
}
function Save-SBSubagentManagePlan($Plan,[string]$BackupRoot) {
    Assert-SBPlainPath $Plan.path
    [void][IO.Directory]::CreateDirectory((Split-Path $Plan.path))
    [void](Write-SBFile $Plan.path $Plan.bytes $Plan.expected $BackupRoot)
    @{state='applied';action=$Plan.action;name=$Plan.name;id=$Plan.id;revision=$Plan.revision;status=$Plan.status}
}
function Get-SBSubagentManageView($Plan,[bool]$Applied) {
    @{state=$(if($Applied){'applied'}else{'preview'});action=$Plan.action;name=$Plan.name;id=$Plan.id;revision=$Plan.revision;status=$Plan.status;previousRevision=$(if($Plan.before){$Plan.before.revision}else{$null});previousStatus=$(if($Plan.before){$Plan.before.status}else{$null});definition=$Plan.after}
}

Export-ModuleMember -Function @('ConvertTo-SBSubagentPlain','Get-SBSubagentManagePlan','Save-SBSubagentManagePlan','Get-SBSubagentManageView','Get-SBSubagentTools','Get-SBSubagentDirectory','Test-SBSubagentDefinition','Resolve-SBSubagentCards','Read-SBSubagentCatalog','Get-SBSubagentSummary','Get-SBSubagentValidateReport','Get-SBSubagentResolveReport','Read-SBSubagentDefinitions','Resolve-SBSubagentPermissions','ConvertTo-SBSubagentExport','Export-SBSubagents','Get-SBSubagentNativeClients','New-SBSubagentActivityRecord')
