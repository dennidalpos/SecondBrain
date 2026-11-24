#requires -Version 7.5
# Behavioral fixtures for subagent definitions (F8). Synthetic data only; no real dossier is touched.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Subagents.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Activity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:subChecks=0
function Assert-Sub($Condition,[string]$Message){if(!$Condition){throw ('FAIL SUBAGENTS: '+$Message)};$script:subChecks++}
function Reject-Sub([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Sub $rejected $Message}
$root=Join-Path (Get-SBTestRoot) ('subagents-'+[guid]::NewGuid().ToString('N'))
$brain=Join-Path $root 'brain';$dossier=Join-Path $brain 'repos/one';$backups=Join-Path $brain '.runtime/backups';$out=Join-Path $brain '.runtime/export'
[void][IO.Directory]::CreateDirectory($dossier)
$repo='github.com/acme/one'
function New-Def([string]$name,[string[]]$tools=@('get_task','search_knowledge'),[bool]$write=$false){
    [ordered]@{schemaVersion=1;name=$name;description='Reads tasks and searches knowledge.';role='You are a read-only reviewer.';context='Start from the tracker task; cite sources.';permissions=[ordered]@{tools=$tools;write=$write}}
}
function Save-Def($def,[string]$file){
    $dir=Join-Path $dossier 'subagents';[void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir $file),(ConvertTo-SBJson $def))
}
$readParent=@{tools=@((Get-SBSubagentTools).read);write=$false}
# Shipped presets (#624): 24 definitions validate against schema 2 and each declares sources, boundaries, tools, writes and output.
$presetFiles=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../directives/agents/presets') -Filter '*.json' -File)
Assert-Sub ($presetFiles.Count -eq 24) 'exactly 24 presets ship'
$presetIds=@{}
foreach($file in $presetFiles){
    $pd=(Get-Content -LiteralPath $file.FullName -Raw)|ConvertFrom-Json -AsHashtable
    Assert-Sub (Test-SBSubagentDefinition $pd) ('preset valid: '+$file.Name)
    Assert-Sub ($pd.schemaVersion -eq 2 -and $pd.name -ceq $file.BaseName -and !$presetIds.ContainsKey($pd.id)) ('preset identity: '+$file.Name)
    $presetIds[$pd.id]=$true
    foreach($label in 'Sources: ','Boundaries: ','Tools: ','Writes: ','Expected output: '){Assert-Sub $pd.context.Contains($label) ('preset declares '+$label+': '+$file.Name)}
    Assert-Sub $pd.context.Contains('Tools: '+(@($pd.permissions.tools) -join ', ')+'.') ('preset Tools line matches permissions: '+$file.Name)
    $readOnlyLine=$pd.context.Contains('Writes: none; the preset is read-only.')
    Assert-Sub (!($readOnlyLine -and $pd.permissions.write)) ('preset Writes line matches write flag: '+$file.Name)
    Assert-Sub ($pd.status -ceq 'active' -and $pd.bounds.depth -eq 1 -and $pd.output.kind -cin @('text','report')) ('preset status, depth and output: '+$file.Name)
}
# Fixture evaluations (#625): every preset has one synthetic scenario; the definition must fit it (static evaluation, no live client).
$evalFile=Join-Path $PSScriptRoot '../directives/agents/evaluations/fixtures.json'
$evalDoc=Get-Content -LiteralPath $evalFile -Raw|ConvertFrom-Json
$evals=@($evalDoc.evaluations)
Assert-Sub ($evals.Count -eq $presetFiles.Count) 'one fixture evaluation per preset'
$evalSeen=@{}
foreach($ev in $evals){
    $evFile=@($presetFiles|Where-Object {$_.BaseName -ceq $ev.preset})
    Assert-Sub ($evFile.Count -eq 1 -and !$evalSeen.ContainsKey($ev.preset)) ('evaluation targets one preset: '+$ev.preset)
    $evalSeen[$ev.preset]=$true
    $pd=Get-Content -LiteralPath $evFile[0].FullName -Raw|ConvertFrom-Json
    Assert-Sub ($ev.id -ceq $pd.id -and -not [string]::IsNullOrWhiteSpace($ev.scenario)) ('evaluation id and scenario: '+$ev.preset)
    $evTools=@($pd.permissions.tools)
    foreach($t in @($ev.requiredTools)){Assert-Sub ($evTools -contains $t) ('scenario tool '+$t+' allowed: '+$ev.preset)}
    $hasWriteTool=($evTools -contains 'submit_dossier_write')
    Assert-Sub ([bool]$ev.dossierWrite -eq [bool]$pd.permissions.write -and $hasWriteTool -eq [bool]$pd.permissions.write) ('scenario write need matches permissions: '+$ev.preset)
    Assert-Sub ($pd.output.kind -ceq $ev.outputKind) ('scenario output kind: '+$ev.preset)
    Assert-Sub ($pd.context.Contains($ev.expectedOutputPhrase) -and $pd.context.Contains($ev.expectedBoundaryPhrase)) ('scenario output and boundary declared: '+$ev.preset)
    $evParent=@{tools=@((Get-SBSubagentTools).read)+@((Get-SBSubagentTools).write)+@((Get-SBSubagentTools).special);write=$true}
    $evPerm=Resolve-SBSubagentPermissions (ConvertTo-SBJson $pd|ConvertFrom-Json -AsHashtable) $evParent
    Assert-Sub ($evPerm.tools.Count -eq $evTools.Count) ('scenario permissions resolve under a full parent: '+$ev.preset)
    if($pd.permissions.write){Reject-Sub { Resolve-SBSubagentPermissions (ConvertTo-SBJson $pd|ConvertFrom-Json -AsHashtable) $readParent } ('write preset refused under a read-only parent: '+$ev.preset)}
}
# Definition format.
Assert-Sub (Test-SBSubagentDefinition (New-Def 'reviewer')) 'valid definition accepted'
$cases=@(
    @{n='unknown field';f={$d=New-Def 'a';$d.token='x';$d}},
    @{n='bad name';f={New-Def 'Bad Name'}},
    @{n='unknown tool';f={New-Def 'a' @('rm_rf')}},
    @{n='duplicate tool';f={New-Def 'a' @('get_task','get_task')}},
    @{n='write tool without write flag';f={New-Def 'a' @('submit_dossier_write') $false}},
    @{n='permission field';f={$d=New-Def 'a';$d.permissions.permit='yes';$d}},
    @{n='empty role';f={$d=New-Def 'a';$d.role=' ';$d}},
    @{n='schema 1 with schema 2 fields';f={$d=New-Def 'a';$d.id='agt-0000000a';$d}},
    @{n='schema version 2 without its fields';f={$d=New-Def 'a';$d.schemaVersion=2;$d}},
    @{n='schema version 3';f={$d=New-Def 'a';$d.schemaVersion=3;$d}})
foreach($case in $cases){
    $def=& $case.f
    Reject-Sub { Test-SBSubagentDefinition $def } ('rejected: '+$case.n)
}
# Inherited permissions: never beyond the parent, never trimmed silently.
$perm=Resolve-SBSubagentPermissions (New-Def 'reviewer') $readParent
Assert-Sub ($perm.tools.Count -eq 2 -and !$perm.write -and $perm.inherited) 'effective permissions within the parent'
Reject-Sub { Resolve-SBSubagentPermissions (New-Def 'a' @('check_publication')) $readParent } 'tool beyond the parent is rejected'
Reject-Sub { Resolve-SBSubagentPermissions (New-Def 'a' @('get_task','submit_dossier_write') $true) $readParent } 'write tool beyond a read-only parent is rejected'
Reject-Sub { Resolve-SBSubagentPermissions (New-Def 'a' @('get_task') $true) $readParent } 'write flag beyond a read-only parent is rejected'
$writeParent=@{tools=@((Get-SBSubagentTools).read+(Get-SBSubagentTools).write);write=$true}
$w=Resolve-SBSubagentPermissions (New-Def 'w' @('preview_dossier_write','submit_dossier_write') $true) $writeParent
Assert-Sub ($w.write -and $w.writeAuthorization -ceq 'parent-reviewed-mcp-write') 'write stays bound to the parent reviewed write path'
Reject-Sub { Resolve-SBSubagentPermissions (New-Def 'a') @{tools=@('get_task')} } 'malformed parent is rejected'
# Dossier asset reading.
Assert-Sub (@(Read-SBSubagentDefinitions $dossier).Count -eq 0) 'no definitions yields an empty list'
# #690: a dossier without subagents/ gives empty reports, also for the bare $null the pipeline yields.
$noneEntries=Read-SBSubagentDefinitions $dossier
$noneValidate=ConvertFrom-Json (ConvertTo-SBJson (Get-SBSubagentValidateReport $noneEntries)) -AsHashtable
Assert-Sub ($noneValidate.state -ceq 'valid' -and @($noneValidate.definitions).Count -eq 0) 'Validate report is empty without a subagents folder'
$noneResolve=ConvertFrom-Json (ConvertTo-SBJson (Get-SBSubagentResolveReport $noneEntries @{tools=@('get_task');write=$false})) -AsHashtable
Assert-Sub (@($noneResolve.agents).Count -eq 0) 'Resolve report is empty without a subagents folder'
Save-Def (New-Def 'reviewer') 'reviewer.json'
Save-Def (New-Def 'planner' @('get_ready_tasks','get_task')) 'planner.json'
$entries=@(Read-SBSubagentDefinitions $dossier)
Assert-Sub ($entries.Count -eq 2 -and $entries[0].definition.name -ceq 'planner') 'definitions are read in name order'
Save-Def (New-Def 'other') 'mismatch.json'
Reject-Sub { Read-SBSubagentDefinitions $dossier } 'file name must match the definition name'
Remove-Item (Join-Path $dossier 'subagents/mismatch.json')
[IO.File]::WriteAllText((Join-Path $dossier 'subagents/notes.txt'),'x')
Reject-Sub { Read-SBSubagentDefinitions $dossier } 'foreign file in the asset folder is rejected'
Remove-Item (Join-Path $dossier 'subagents/notes.txt')
# Export through adapters.
$preview=Export-SBSubagents $dossier 'claude-code' $readParent $out $backups
Assert-Sub ($preview.state -eq 'preview' -and $preview.count -eq 2 -and !(Test-Path $out)) 'export preview writes nothing'
$applied=Export-SBSubagents $dossier 'claude-code' $readParent $out $backups -Apply
$md=Get-Content -LiteralPath (Join-Path $out '.claude/agents/reviewer.md') -Raw
Assert-Sub ($applied.state -eq 'applied' -and $md.StartsWith("---`nname: reviewer`n") -and $md.Contains('tools: mcp__secondbrain__get_task, mcp__secondbrain__search_knowledge') -and !$md.Contains('submit_dossier_write')) 'claude-code export lists only the allowed MCP tools'
Assert-Sub ((Export-SBSubagents $dossier 'claude-code' $readParent $out $backups -Apply).state -eq 'unchanged') 'export is idempotent'
$codex=Export-SBSubagents $dossier 'codex' $readParent $out $backups -Apply
$toml=Get-Content -LiteralPath (Join-Path $out '.codex/agents/reviewer.toml') -Raw
Assert-Sub ($codex.state -eq 'applied' -and $toml.StartsWith("name = `"reviewer`"`n") -and $toml.Contains('developer_instructions = "') -and !$codex.files[0].liveVerified) 'codex gets a native TOML agent, not live-verified'
Assert-Sub ($toml.Contains('Allowed SecondBrain MCP tools: get_task, search_knowledge') -and !$toml.Contains('submit_dossier_write')) 'codex instructions declare only the allowed tools'
$codexFields=@($codex.files[0].unsupported|ForEach-Object {$_.field})
Assert-Sub ('permissions.tools' -in $codexFields -and 'permissions.write' -in $codexFields -and $codex.files[0].enforcement.tools -ceq 'declared' -and @($codex.files[0].enforcement.enforcedByClient).Count -eq 0) 'codex reports unsupported permissions as declared only'
$gem=Export-SBSubagents $dossier 'gemini' $readParent $out $backups -Apply
$gmd=Get-Content -LiteralPath (Join-Path $out '.gemini/agents/reviewer.md') -Raw
Assert-Sub ($gem.state -eq 'applied' -and $gmd.StartsWith("---`nname: reviewer`n") -and $gmd.Contains("kind: local`ntools:`n  - mcp_secondbrain_get_task`n  - mcp_secondbrain_search_knowledge`n") -and !$gmd.Contains('submit_dossier_write')) 'gemini export lists only the allowed MCP tools'
Assert-Sub ($gem.files[0].enforcement.tools -ceq 'client-allowlist' -and $gem.files[0].format -ceq 'gemini-markdown') 'gemini tool allowlist is enforced by the client'
Assert-Sub ((Export-SBSubagents $dossier 'codex' $readParent $out $backups -Apply).state -eq 'unchanged' -and (Export-SBSubagents $dossier 'gemini' $readParent $out $backups -Apply).state -eq 'unchanged') 'native exports are idempotent'
$probed=Export-SBSubagents $dossier 'gemini' $readParent $out $backups -Capabilities @{installed=$false;status='not-found';version=$null}
Assert-Sub ($probed.probe.provider -ceq 'gemini' -and !$probed.probe.installed -and $probed.probe.status -ceq 'not-found') 'probe result is reported with the export'
$norm=Export-SBSubagents $dossier 'vscode' $readParent $out $backups -Apply
$json=Read-SBJson (Join-Path $out 'subagents/reviewer.vscode.json') $null
Assert-Sub ($norm.state -eq 'applied' -and $json.permissions.write -eq $false -and !$norm.files[0].liveVerified) 'clients without a native format get the normalized definition'
Reject-Sub { Export-SBSubagents $dossier 'claude-code' @{tools=@('get_task');write=$false} $out $backups } 'export fails when a definition exceeds the parent'
Reject-Sub { Export-SBSubagents $dossier 'nonexistent' $readParent $out $backups } 'unknown client rejected'
# Schema 2 (asset-contracts section 4): identity, revisioning, cards with mode check, output contract, bounds.
$catalog=@{schemaVersion=1;prompts=@(
    @{id='pmt-0000a001';code='SYN01';mode='read'},
    @{id='pmt-0000a002';code='SYN02';mode='verify'},
    @{id='pmt-0000a003';code='SYN03';mode='write'},
    @{id='pmt-0000a004';code='SYN04';mode='read';role='analysis.task'},
    @{id='pmt-0000a005';code='SYN05';mode='read';status='retired'},
    @{id='pmt-0000a006';code='SYN06';mode='read';status='draft'})}
function New-Def2([string]$name,[string[]]$cards=@(),[bool]$write=$false){
    $d=New-Def $name $(if($write){@('get_task','preview_dossier_write','submit_dossier_write')}else{@('get_task','search_knowledge')}) $write
    $d.schemaVersion=2;$d.id='agt-0000b001';$d.revision=1;$d.status='active'
    $d.output=[ordered]@{kind='report'};$d.bounds=[ordered]@{depth=1;budget=[ordered]@{turns=20}}
    if($cards.Count){$d.cards=$cards}
    $d
}
Assert-Sub (Test-SBSubagentDefinition (New-Def2 'reviewer')) 'schema 2 definition accepted'
Assert-Sub (Test-SBSubagentDefinition (New-Def2 'reviewer' @('pmt-0000a001','analysis.task'))) 'schema 2 definition with cards accepted'
$v2def=New-Def2 'reviewer'
$v2def.model=[ordered]@{provider='gemini';name='gemini-2.5-pro'}
$v2perm=Resolve-SBSubagentPermissions $v2def $readParent
$v2claude=ConvertTo-SBSubagentExport $v2def $v2perm 'claude-code'
$v2gemini=ConvertTo-SBSubagentExport $v2def $v2perm 'gemini'
$v2codex=ConvertTo-SBSubagentExport $v2def $v2perm 'codex'
Assert-Sub ('bounds' -in @($v2claude.unsupported|ForEach-Object {$_.field}) -and 'model' -in @($v2claude.unsupported|ForEach-Object {$_.field}) -and !$v2claude.content.Contains('model:')) 'claude export reports bounds and a foreign model preference instead of dropping them'
Assert-Sub ($v2gemini.content.Contains("model: `"gemini-2.5-pro`"`n") -and $v2gemini.content.Contains("max_turns: 20`n") -and 'bounds' -notin @($v2gemini.unsupported|ForEach-Object {$_.field}) -and 'cards' -in @($v2gemini.unsupported|ForEach-Object {$_.field})) 'gemini export maps model and turn budget and reports the rest'
Assert-Sub ($v2codex.content.Contains('"description"') -or $v2codex.content.Contains('description = ')) 'codex export carries the description'
Assert-Sub ($v2claude.enforcement.write -ceq 'no-write-tool-in-allowlist' -and $v2codex.enforcement.write -ceq 'declared') 'write restriction is enforceable only where the client has an allowlist'
$cases2=@(
    @{n='missing id';f={$d=New-Def2 'a';$d.Remove('id');$d}},
    @{n='bad id';f={$d=New-Def2 'a';$d.id='agt-XYZ';$d}},
    @{n='prompt id as agent id';f={$d=New-Def2 'a';$d.id='pmt-0000b001';$d}},
    @{n='revision zero';f={$d=New-Def2 'a';$d.revision=0;$d}},
    @{n='revision string';f={$d=New-Def2 'a';$d.revision='1';$d}},
    @{n='unknown status';f={$d=New-Def2 'a';$d.status='expired';$d}},
    @{n='replacedBy on active';f={$d=New-Def2 'a';$d.replacedBy='agt-0000b002';$d}},
    @{n='replacedBy itself';f={$d=New-Def2 'a';$d.status='deprecated';$d.replacedBy=$d.id;$d}},
    @{n='cards as string';f={$d=New-Def2 'a';$d.cards='pmt-0000a001';$d}},
    @{n='card code instead of id or role';f={New-Def2 'a' @('SYN01')}},
    @{n='duplicate card';f={New-Def2 'a' @('pmt-0000a001','pmt-0000a001')}},
    @{n='missing output';f={$d=New-Def2 'a';$d.Remove('output');$d}},
    @{n='unknown output kind';f={$d=New-Def2 'a';$d.output.kind='file';$d}},
    @{n='object output without schema';f={$d=New-Def2 'a';$d.output.kind='object';$d}},
    @{n='output schema outside config';f={$d=New-Def2 'a';$d.output=[ordered]@{kind='object';schema='../x.json'};$d}},
    @{n='missing bounds';f={$d=New-Def2 'a';$d.Remove('bounds');$d}},
    @{n='depth 2';f={$d=New-Def2 'a';$d.bounds.depth=2;$d}},
    @{n='depth 0';f={$d=New-Def2 'a';$d.bounds.depth=0;$d}},
    @{n='missing budget';f={$d=New-Def2 'a';$d.bounds.Remove('budget');$d}},
    @{n='empty budget';f={$d=New-Def2 'a';$d.bounds.budget=@{};$d}},
    @{n='unknown budget unit';f={$d=New-Def2 'a';$d.bounds.budget=@{tokens=5};$d}},
    @{n='budget turns zero';f={$d=New-Def2 'a';$d.bounds.budget=@{turns=0};$d}},
    @{n='budget minutes too high';f={$d=New-Def2 'a';$d.bounds.budget=@{minutes=2000};$d}},
    @{n='unknown bounds field';f={$d=New-Def2 'a';$d.bounds.parallel=2;$d}},
    @{n='i18n block';f={$d=New-Def2 'a';$d.i18n=@{};$d}})
foreach($case in $cases2){
    $def=& $case.f
    Reject-Sub { Test-SBSubagentDefinition $def } ('rejected schema 2: '+$case.n)
}
$ok=Test-SBSubagentDefinition $(& {$d=New-Def2 'a';$d.status='deprecated';$d.replacedBy='agt-0000b002';$d.output=[ordered]@{kind='object';schema='config/synthetic-result.json'};$d.bounds.budget=[ordered]@{turns=5;minutes=30};$d})
Assert-Sub $ok 'deprecated definition with replacedBy, object output and both budget units accepted'
# Cards resolve by ID or role and never above the effective mode.
$resolved=Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a001','analysis.task')) $catalog
Assert-Sub ($resolved.Count -eq 2 -and $resolved[0].code -ceq 'SYN01' -and $resolved[1].id -ceq 'pmt-0000a004' -and $resolved[1].mode -ceq 'read') 'cards resolve by id and role'
Assert-Sub ((Resolve-SBSubagentCards (New-Def2 'w' @('pmt-0000a002','pmt-0000a003') $true) $catalog).Count -eq 2) 'write agent composes verify and write cards'
Assert-Sub ((Resolve-SBSubagentCards (New-Def 'one') $catalog).Count -eq 0) 'schema 1 has no cards'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a003')) $catalog } 'write card above a read-only agent is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a002')) $catalog } 'verify card above a read-only agent is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000ffff')) $catalog } 'unknown card id is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('stop')) $catalog } 'unknown role is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a005')) $catalog } 'retired card is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a006')) $catalog } 'draft card is rejected'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @('pmt-0000a001')) $null } 'cards without a catalog are rejected'
$realCatalog=Read-SBSubagentCatalog (Join-Path $PSScriptRoot '..')
$realRead=@($realCatalog.prompts|Where-Object {$_.mode -ceq 'read'})[0]
$realWrite=@($realCatalog.prompts|Where-Object {$_.mode -ceq 'write'})[0]
Assert-Sub ((Resolve-SBSubagentCards (New-Def2 'a' @($realRead.id)) $realCatalog)[0].mode -ceq 'read') 'a real read card resolves against the public catalog'
Reject-Sub { Resolve-SBSubagentCards (New-Def2 'a' @($realWrite.id)) $realCatalog } 'a real write card is rejected for a read-only agent'
# Dossier reading, Resolve summary and export of schema 2 next to schema 1.
$dossier2=Join-Path $brain 'repos/two';$out2=Join-Path $brain '.runtime/export2'
$dir2=Join-Path $dossier2 'subagents';[void][IO.Directory]::CreateDirectory($dir2)
$v1=New-Def 'reviewer';$v2=New-Def2 'reviewer' @('analysis.task')
[IO.File]::WriteAllText((Join-Path $dir2 'reviewer.json'),(ConvertTo-SBJson $v2))
$e2=@(Read-SBSubagentDefinitions $dossier2 $catalog)
Assert-Sub ($e2.Count -eq 1 -and $e2[0].cards.Count -eq 1 -and $e2[0].cards[0].code -ceq 'SYN04') 'schema 2 definitions are read with resolved cards'
Reject-Sub { Read-SBSubagentDefinitions $dossier2 } 'schema 2 cards need the catalog when read'
$s2=Get-SBSubagentSummary $v2
Assert-Sub ($s2.id -ceq 'agt-0000b001' -and $s2.revision -eq 1 -and $s2.status -ceq 'active' -and $s2.bounds.depth -eq 1 -and $s2.bounds.budget.turns -eq 20 -and $s2.output.kind -ceq 'report' -and $s2.maxCardMode -ceq 'read') 'summary reports identity, bounds, output and card mode'
$s1=Get-SBSubagentSummary $v1
Assert-Sub ($s1.schemaVersion -eq 1 -and $s1.bounds.depth -eq 1 -and $null -eq $s1.bounds.budget -and $s1.status -ceq 'active') 'schema 1 summary has depth 1 and no budget'
$md1=(ConvertTo-SBSubagentExport $v1 (Resolve-SBSubagentPermissions $v1 $readParent) 'claude-code').content
$md2=(ConvertTo-SBSubagentExport $v2 (Resolve-SBSubagentPermissions $v2 $readParent) 'claude-code').content
Assert-Sub ($md1 -ceq $md2) 'claude-code export is unchanged by schema 2'
$n2=(ConvertTo-SBSubagentExport $v2 (Resolve-SBSubagentPermissions $v2 $readParent) 'vscode').content|ConvertFrom-Json -AsHashtable
Assert-Sub ($n2.schemaVersion -eq 2 -and $n2.id -ceq 'agt-0000b001' -and $n2.bounds.depth -eq 1 -and $n2.cards[0] -ceq 'analysis.task') 'normalized export carries schema 2 fields'
$draft=New-Def2 'drafted';$draft.id='agt-0000b003';$draft.status='draft'
[IO.File]::WriteAllText((Join-Path $dir2 'drafted.json'),(ConvertTo-SBJson $draft))
$x2=Export-SBSubagents $dossier2 'claude-code' $readParent $out2 $backups -Catalog $catalog
Assert-Sub ($x2.count -eq 1 -and $x2.skipped.Count -eq 1 -and $x2.skipped[0].status -ceq 'draft') 'draft definitions are not exported'
$dup=New-Def2 'twin';$dup.cards=@('analysis.task')
[IO.File]::WriteAllText((Join-Path $dir2 'twin.json'),(ConvertTo-SBJson $dup))
Reject-Sub { Read-SBSubagentDefinitions $dossier2 $catalog } 'duplicate agent ids are rejected'
Remove-Item (Join-Path $dir2 'twin.json')
# Validate and Resolve reports (the CLI prints these) over schema 1 and 2 side by side.
$old=New-Def 'legacy';[IO.File]::WriteAllText((Join-Path $dir2 'legacy.json'),(ConvertTo-SBJson $old))
$e3=@(Read-SBSubagentDefinitions $dossier2 $catalog)
$vr=ConvertFrom-Json (ConvertTo-SBJson (Get-SBSubagentValidateReport $e3)) -AsHashtable
Assert-Sub ($vr.state -ceq 'valid' -and $vr.definitions.Count -eq 3 -and @($vr.definitions|Where-Object {$_.name -ceq 'legacy' -and $_.schemaVersion -eq 1 -and $null -eq $_.id}).Count -eq 1 -and @($vr.definitions|Where-Object {$_.name -ceq 'reviewer' -and $_.id -ceq 'agt-0000b001' -and $_.cards[0].mode -ceq 'read'}).Count -eq 1) 'Validate report lists schema, id and cards'
$rr=ConvertFrom-Json (ConvertTo-SBJson (Get-SBSubagentResolveReport $e3 $readParent)) -AsHashtable
$ra=@($rr.agents|Where-Object {$_.name -ceq 'reviewer'})[0];$rl=@($rr.agents|Where-Object {$_.name -ceq 'legacy'})[0]
Assert-Sub ($ra.bounds.depth -eq 1 -and $ra.bounds.budget.turns -eq 20 -and $ra.cards[0].id -ceq 'pmt-0000a004' -and $ra.revision -eq 1 -and $ra.status -ceq 'active' -and $ra.output.kind -ceq 'report' -and $ra.tools.Count -eq 2 -and !$ra.write) 'Resolve report carries bounds, cards and effective permissions'
Assert-Sub ($rl.schemaVersion -eq 1 -and $rl.bounds.depth -eq 1 -and $null -eq $rl.bounds.budget -and $rl.cards.Count -eq 0) 'Resolve report keeps schema 1 with fixed depth'
$over=New-Def2 'overreach' @('pmt-0000a003');$over.id='agt-0000b004'
[IO.File]::WriteAllText((Join-Path $dir2 'overreach.json'),(ConvertTo-SBJson $over))
Reject-Sub { Read-SBSubagentDefinitions $dossier2 $catalog } 'Validate rejects a stored definition with a card above its mode'
Remove-Item (Join-Path $dir2 'overreach.json')
$deep=New-Def2 'deep';$deep.id='agt-0000b005';$deep.bounds.depth=2
[IO.File]::WriteAllText((Join-Path $dir2 'deep.json'),(ConvertTo-SBJson $deep))
Reject-Sub { Read-SBSubagentDefinitions $dossier2 $catalog } 'Validate rejects a stored definition with depth other than 1'
Remove-Item (Join-Path $dir2 'deep.json')
# Register: subagent jobs reference the parent session.
$log=Join-Path $dossier 'history/activity/report.md'
# Management operations (#622): create, edit, revise and retire with validation; the plan alone never writes.
$dossier3=Join-Path $brain 'repos/manage';[void][IO.Directory]::CreateDirectory($dossier3)
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition (New-Def2 'planner' @('analysis.task'))
Assert-Sub ($plan.revision -eq 1 -and $plan.status -eq 'active' -and $plan.id -cmatch '^agt-[0-9a-f]{8}$' -and !(Test-Path -LiteralPath $plan.path)) 'create plan assigns revision 1 and writes nothing'
$d=New-Def2 'planner';$d.Remove('id');$d.Remove('revision');$d.Remove('status')
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $d
Assert-Sub ($plan.status -eq 'draft' -and $plan.revision -eq 1 -and $plan.id -cmatch '^agt-[0-9a-f]{8}$') 'create without id, revision and status gives an ID, revision 1 and draft'
[void](Save-SBSubagentManagePlan $plan $backups)
$entries3=@(Read-SBSubagentDefinitions $dossier3 $catalog)
Assert-Sub ($entries3.Count -eq 1 -and $entries3[0].definition.name -ceq 'planner') 'created definition validates and is listed'
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $d } 'creating an existing name is refused'
$dup=New-Def2 'other';$dup.id=$plan.id
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $dup } 'a used ID is never reused'
$bad=New-Def2 'badone' @('pmt-0000a003')
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $bad } 'a card above the agent permissions is refused on create'
$withRev=New-Def2 'rev2';$withRev.revision=2
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $withRev } 'a new definition starts at revision 1'
# Wizard (#623): optional model, and the preview carries the definition that Save writes.
$wm=New-Def2 'wizard-agent';$wm.Remove('id');$wm.model=[ordered]@{provider='claude';name='opus'}
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $wm
$view=Get-SBSubagentManageView $plan $false
Assert-Sub ($view.definition.model.provider -ceq 'claude' -and $view.definition.id -ceq $plan.id) 'the manage view carries the definition with its assigned ID'
[void](Save-SBSubagentManagePlan $plan $backups)
$saved=(Read-SBText (Join-Path $dossier3 'subagents/wizard-agent.json'))|ConvertFrom-Json -AsHashtable
Assert-Sub ((ConvertTo-SBJson $saved) -ceq (ConvertTo-SBJson $view.definition)) 'the saved file equals the previewed definition'
foreach($badModel in @(@{provider='any';name='x'},@{provider='other'},@{provider='claude';name='bad name!'},@{provider='claude';extra=1},'claude')){
    $wb=New-Def2 'wizard-bad';$wb.Remove('id');$wb.model=$badModel
    Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition $wb } 'an invalid model is refused'
}
# Edit: wording only, no revision bump.
$edit=@{description='A clearer description.'}
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Edit -Name planner -Definition $edit
Assert-Sub ($plan.revision -eq 1 -and $plan.after.description -ceq 'A clearer description.') 'edit changes the wording and keeps the revision'
[void](Save-SBSubagentManagePlan $plan $backups)
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Edit -Name planner -Definition @{role='A different role.'} } 'edit refuses a contract field'
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Edit -Name planner -Definition $edit } 'edit with no change is refused'
# Revise: next revision, compatible changes only.
$current3=@(Read-SBSubagentDefinitions $dossier3 $catalog)[0].definition
$rev=ConvertTo-SBSubagentPlain $current3;$rev.role='You review tasks and cite sources.'
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Revise -Name planner -Definition $rev
Assert-Sub ($plan.revision -eq 2 -and $plan.id -ceq $current3.id) 'revise bumps the revision and keeps the ID'
[void](Save-SBSubagentManagePlan $plan $backups)
$widen=ConvertTo-SBSubagentPlain $plan.after;$widen.permissions=[ordered]@{tools=@('get_task','search_knowledge','preview_dossier_write','submit_dossier_write');write=$true}
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Revise -Name planner -Definition $widen } 'a widening revision is refused (new ID required)'
$skip=ConvertTo-SBSubagentPlain $plan.after;$skip.revision=5;$skip.role='Another role.'
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Revise -Name planner -Definition $skip } 'a revision must be the next one'
$rename=ConvertTo-SBSubagentPlain $plan.after;$rename.id='agt-0000ffff';$rename.role='Z.'
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Revise -Name planner -Definition $rename } 'the ID cannot change in a revision'
# Retire: forward transitions only, replacedBy must exist.
$successor=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Create -Definition (New-Def2 'planner-next')
[void](Save-SBSubagentManagePlan $successor $backups)
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Retire -Name planner -Status deprecated -ReplacedBy 'agt-0000dead' } 'replacedBy must name an existing definition'
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Retire -Name planner -Status deprecated -ReplacedBy $successor.id
Assert-Sub ($plan.status -eq 'deprecated' -and $plan.after.replacedBy -ceq $successor.id -and $plan.revision -eq 2) 'deprecate records replacedBy without a revision bump'
[void](Save-SBSubagentManagePlan $plan $backups)
$plan=Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Retire -Name planner -Status retired
[void](Save-SBSubagentManagePlan $plan $backups)
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Retire -Name planner -Status deprecated } 'a retired definition cannot go back'
Assert-Sub (@(Read-SBSubagentDefinitions $dossier3 $catalog|Where-Object {$_.definition.name -ceq 'planner' -and $_.definition.status -ceq 'retired'}).Count -eq 1) 'the retired definition stays on disk with its ID'
Reject-Sub { Get-SBSubagentManagePlan -Dossier $dossier3 -Catalog $catalog -Action Retire -Name missing -Status retired } 'retiring an unknown definition is refused'
$config=@{activityLogEnabled=$true}
$when='2026-11-07T10:00:00Z'
$parentRec=@{schemaVersion=1;eventId=(Get-SBTextHash 'p').Substring(0,32).ToLowerInvariant();user='SYNTH\ada';repository=$repo;taskId='T-1';session='parent-1';when=$when;where='C:\work\one';computer='PC1';outcome='started';detail='parent job'}
$child=New-SBSubagentActivityRecord $repo 'SYNTH\ada' 'PC1' 'T-1' 'parent-1' 'reviewer' 'child-1' '2026-11-07T10:05:00Z' 'completed' 'reviewed task'
Reject-Sub { Add-SBActivityRecords $dossier @($child) $backups $config -Apply } 'child record without a known parent is rejected'
Assert-Sub (!(Test-Path $log)) 'rejected child leaves no log'
Assert-Sub ((Add-SBActivityRecords $dossier @($parentRec,$child) $backups $config -Apply).added -eq 2) 'parent and child append together'
$read=Read-SBActivityLog $dossier
Assert-Sub ($read.records[1].parent -ceq 'parent-1' -and $read.records[1].agent -ceq 'reviewer') 'child record keeps parent and agent'
Assert-Sub ((Add-SBActivityRecords $dossier @($child) $backups $config -Apply).state -eq 'unchanged') 'child append is idempotent'
$mutations=@({param($r) $r.Remove('agent')},{param($r) $r.parent=$r.session},{param($r) $r.agent='Bad Agent'},{param($r) $r.parent='bad parent!'},{param($r) $r.source='trace'})
foreach($mutate in $mutations){
    $bad=@{}+$child;$bad.eventId=(Get-SBTextHash ([guid]::NewGuid().ToString())).Substring(0,32).ToLowerInvariant();& $mutate $bad|Out-Null
    Reject-Sub { Test-SBActivityRecord $bad } 'invalid subagent record rejected'
}
$orphan=New-SBSubagentActivityRecord $repo 'SYNTH\ada' 'PC1' 'T-1' 'other-repo-parent' 'reviewer' 'child-2' '2026-11-07T11:00:00Z' 'started' 'x'
Reject-Sub { Add-SBActivityRecords $dossier @($orphan) $backups $config -Apply } 'unknown parent session is rejected on append'
# Agent runs (#627): start, stop, inspect and resume on fixtures; no live agent and no service.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.AgentRuns.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Decisions.psm1') -Force
$runRoot=Join-Path $brain '.runtime/agent-runs'
$runDef=[ordered]@{schemaVersion=2;id='agt-0a0b0c0d';name='runner-fixture';revision=1;status='active'}
$fixtureProc=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -PassThru -WindowStyle Hidden
try{
    $started=Start-SBAgentRun -RunRoot $runRoot -Repository $repo -Definition $runDef -TaskId 'T-1' -ProcessId $fixtureProc.Id
    Assert-Sub ($started.state -ceq 'running' -and $started.attempts -eq 1 -and $started.processAlive) 'run starts with a live recorded process'
    Assert-Sub ((Get-SBAgentRunInspection $runRoot $started.runId).agent.id -ceq 'agt-0a0b0c0d') 'inspect shows the definition ID, not a copy'
    Assert-Sub ((Get-SBAgentRunInspection $runRoot).count -eq 1) 'inspect lists the runs'
    Reject-Sub { Start-SBAgentRun -RunRoot $runRoot -Repository $repo -Definition ([ordered]@{schemaVersion=2;id='agt-0a0b0c0e';name='x';revision=1;status='draft'}) } 'a draft definition cannot run'
    Reject-Sub { Resume-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Dossier $dossier } 'a running run cannot resume'
    $stopped=Stop-SBAgentRun -RunRoot $runRoot -RunId $started.runId
    Assert-Sub ($stopped.state -ceq 'stopped' -and $stopped.result -ceq 'process-stopped' -and !$stopped.processAlive) 'stop ends the recorded process'
    Assert-Sub ($fixtureProc.WaitForExit(10000)) 'the fixture process is gone'
    Reject-Sub { Stop-SBAgentRun -RunRoot $runRoot -RunId $started.runId } 'a stopped run cannot stop again'
    $resumed=Resume-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Dossier $dossier
    Assert-Sub ($resumed.state -ceq 'running' -and $resumed.attempts -eq 2) 'resume adds an attempt'
    $opened=New-SBDecisionRecord -Data (Read-SBDecisions $dossier $repo).data -Kind choice -Question 'Which path?' -Options @(@{id='a';label='A';description='A'},@{id='b';label='B';description='B'}) -Scope task -Through structured-tool -AskedBy agent -TaskId 'T-1'
    $decisionId=$opened.record.id
    [IO.File]::WriteAllText((Get-SBDecisionPath $dossier),(ConvertTo-SBJson $opened.data))
    $waiting=Suspend-SBAgentRun -RunRoot $runRoot -RunId $started.runId -DecisionId $decisionId
    Assert-Sub ($waiting.state -ceq 'waiting-user' -and $waiting.decisionId -ceq $decisionId) 'run waits on a decision'
    Reject-Sub { Resume-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Dossier $dossier } 'an open decision blocks resume'
    $answered=Set-SBDecisionAnswer -Data (Read-SBDecisions $dossier $repo).data -Id $decisionId -Option 'a'
    [IO.File]::WriteAllText((Get-SBDecisionPath $dossier),(ConvertTo-SBJson $answered.data))
    Assert-Sub ((Resume-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Dossier $dossier).attempts -eq 3) 'an answered decision lets the run resume'
    $done=Stop-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Outcome finished
    Assert-Sub ($done.state -ceq 'finished' -and !$done.processAlive) 'a run finishes'
    Reject-Sub { Resume-SBAgentRun -RunRoot $runRoot -RunId $started.runId -Dossier $dossier } 'a finished run cannot resume'
    Reject-Sub { Get-SBAgentRunInspection $runRoot 'run-zzzzzzzz' } 'an invalid run ID is refused'
}finally{if(!$fixtureProc.HasExited){$fixtureProc.Kill($true)}}
# Workflow runs (#576): pinned state, gates, stop and resume on the shipped wf-dossier-tidy (confirm gate on its second step); nothing is launched.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.WorkflowRuns.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Prompts.psm1') -Force
$realBrain=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$flowCatalog=Read-SBWorkflowCatalog $realBrain
$flow=@(Read-SBPromptWorkflows $realBrain $flowCatalog|Where-Object key -ceq 'wf-dossier-tidy')[0]
$wfRoot=Join-Path $brain '.runtime/workflow-runs'
$wf=Start-SBWorkflowRun -BrainRoot $realBrain -RunRoot $wfRoot -Repository $repo -Workflow $flow -Catalog $flowCatalog -Objective 'Tidy'
Assert-Sub ($wf.state -ceq 'running' -and $wf.total -eq 3 -and $wf.done -eq 0 -and $wf.workflow.id -ceq $flow.id -and $wf.workflow.revision -eq $flow.revision) 'a workflow run starts pinned to the workflow ID and revision'
$wfFile=Join-Path $wfRoot ($wf.runId+'/workflow-run.json')
$wfText=Get-Content -Raw -LiteralPath $wfFile
Assert-Sub ((Read-SBWorkflowRun $wfRoot $wf.runId).run.pinned.Count -eq 3 -and $wfText -notmatch '<role>' -and $wfText -notmatch 'Reorder the tracker: development') 'the state pins card hashes and does not copy card or workflow text'
Assert-Sub ((Test-SBWorkflowRunPins $realBrain $wfRoot $wf.runId).changed.Count -eq 0) 'the pinned cards are unchanged'
Reject-Sub { Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'reorder-tracker' } 'a step that did not start cannot be recorded'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).steps[0].status -ceq 'running') 'an auto step starts at once'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).result -ceq 'running') 'advancing twice does not start another step'
$wf1=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'reorder-tracker' -Evidence 'history/tidy-1'
Assert-Sub ($wf1.done -eq 1 -and $wf1.steps[0].evidence -ceq 'history/tidy-1' -and $wf1.current -ceq 'compact') 'recording a step keeps its evidence and moves to the next'
$gate=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
Assert-Sub ($gate.state -ceq 'waiting-user' -and $gate.steps[1].status -ceq 'waiting-user' -and $gate.steps[1].decisionId -cmatch '^dec-[0-9a-f]{8}$' -and $gate.steps[1].decision.status -ceq 'open') 'a confirm gate opens a decision and the run waits'
Reject-Sub { Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'compact' } 'a gated step cannot be recorded before the answer'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).result -ceq 'waiting') 'advancing does not pass an unanswered gate'
Assert-Sub ((Stop-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).state -ceq 'stopped') 'a waiting run stops'
Reject-Sub { Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId } 'a stopped run does not advance'
$wfBack=Resume-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
Assert-Sub ($wfBack.steps[0].status -ceq 'done' -and $wfBack.steps[1].status -ceq 'waiting-user' -and $wfBack.state -ceq 'waiting-user' -and $wfBack.done -eq 1) 'resume keeps the verified step done and the gate waiting'
Reject-Sub { Set-SBWorkflowGateAnswer -RunRoot $wfRoot -RunId $wf.runId -Step 'reorder-tracker' -Answer yes } 'only a step that waits can be answered'
Assert-Sub ((Set-SBWorkflowGateAnswer -RunRoot $wfRoot -RunId $wf.runId -Step 'compact' -Answer no).state -ceq 'stopped') 'declining a required gate stops the run'
Assert-Sub ((Resume-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).steps[1].status -ceq 'pending') 'after a refusal the step is asked again on resume'
$ask=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
Assert-Sub ($ask.steps[1].status -ceq 'waiting-user' -and $ask.steps[1].decisionId -cne $gate.steps[1].decisionId) 'a refused gate opens a fresh decision'
$yes=Set-SBWorkflowGateAnswer -RunRoot $wfRoot -RunId $wf.runId -Step 'compact' -Answer yes
Assert-Sub ($yes.state -ceq 'running' -and $yes.steps[1].decision.by -ceq 'user' -and $yes.steps[1].status -ceq 'pending') 'the person answering yes lets the step start'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId).steps[1].status -ceq 'running') 'an approved gate starts the step without asking again'
$failedRun=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'compact' -Outcome failed -Evidence 'broke'
Assert-Sub ($failedRun.state -ceq 'failed' -and $failedRun.steps[0].status -ceq 'done') 'a failed step fails the run and leaves done steps alone'
$retry=Resume-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
Assert-Sub ($retry.steps[1].status -ceq 'pending' -and $retry.steps[1].evidence -ceq '' -and $retry.steps[0].status -ceq 'done' -and $retry.state -ceq 'running') 'resume retries the failed step and never repeats a done one'
$null=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
$null=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'compact'
$null=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId
$last=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $wf.runId -Step 'align'
Assert-Sub ($last.state -ceq 'finished' -and $last.done -eq 3 -and !$last.current) 'the last verified step finishes the run'
Reject-Sub { Resume-SBWorkflowRun -RunRoot $wfRoot -RunId $wf.runId } 'a finished run cannot resume'
Assert-Sub ((Get-SBWorkflowRunInspection $wfRoot).count -eq 1) 'inspect lists the runs'
Reject-Sub { Get-SBWorkflowRunInspection $wfRoot 'run-zzzzzzzz' } 'an invalid workflow run ID is refused'
Reject-Sub { Start-SBWorkflowRun -BrainRoot $realBrain -RunRoot $wfRoot -Repository $repo -Workflow $flow -Catalog $flowCatalog -Skip @('compact') } 'a required step cannot be skipped'
Reject-Sub { Start-SBWorkflowRun -BrainRoot $realBrain -RunRoot $wfRoot -Repository 'not an identity' -Workflow $flow -Catalog $flowCatalog } 'an invalid repository identity is refused'
$fixed=@($flowCatalog.prompts)[0]
$optFlow=[ordered]@{id='wfl-0a0b0c0d';key='wf-synthetic';title='t';revision=2;status='active';steps=@([ordered]@{step='one';ref=$fixed.id;kind='required';gate='auto'},[ordered]@{step='two';ref=$fixed.id;kind='optional';gate='auto'},[ordered]@{step='pick';ref=$fixed.id;kind='choice';gate='auto';choices=@($fixed.id,@($flowCatalog.prompts)[1].id)})}
$opt=Start-SBWorkflowRun -BrainRoot $realBrain -RunRoot $wfRoot -Repository $repo -Workflow $optFlow -Catalog $flowCatalog -Skip @('two')
Assert-Sub ($opt.steps[1].status -ceq 'skipped' -and $opt.done -eq 0) 'an optional step can start skipped'
$null=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt.runId;$null=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $opt.runId -Step 'one'
Reject-Sub { Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt.runId -Option 'pmt-ffffffff' } 'a card outside the choices is refused'
# #590: an unfixed choice step opens a step-scoped dec- decision stored in workflow-run.json; the run waits until the person answers.
$pick=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt.runId
Assert-Sub ($pick.state -ceq 'waiting-user' -and $pick.steps[2].status -ceq 'waiting-user' -and $pick.steps[2].decisionId -cmatch '^dec-[0-9a-f]{8}$' -and $pick.steps[2].decision.kind -ceq 'choice' -and $pick.steps[2].decision.status -ceq 'open' -and @($pick.steps[2].decision.options).Count -eq 2) 'an unfixed choice step opens a decision and the run waits'
Assert-Sub ((Read-SBWorkflowRun $wfRoot $opt.runId).run.steps[2].decisionId -ceq $pick.steps[2].decisionId) 'the choice decision is stored in workflow-run.json'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt.runId).result -ceq 'waiting') 'advancing does not pass an unanswered choice'
Reject-Sub { Set-SBWorkflowGateAnswer -RunRoot $wfRoot -RunId $opt.runId -Step 'pick' -Answer 'yes' } 'an answer outside the listed cards is refused'
$picked=Set-SBWorkflowGateAnswer -RunRoot $wfRoot -RunId $opt.runId -Step 'pick' -Answer $fixed.id
Assert-Sub ($picked.state -ceq 'running' -and $picked.steps[2].choice -ceq $fixed.id -and $picked.steps[2].decision.by -ceq 'user' -and $picked.steps[2].status -ceq 'pending') 'the person answering fixes the choice'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt.runId).steps[2].status -ceq 'running') 'an answered choice starts the step'
$opt2=Start-SBWorkflowRun -BrainRoot $realBrain -RunRoot $wfRoot -Repository $repo -Workflow $optFlow -Catalog $flowCatalog -Skip @('two')
$null=Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt2.runId;$null=Complete-SBWorkflowStep -RunRoot $wfRoot -RunId $opt2.runId -Step 'one'
Assert-Sub ((Step-SBWorkflowRun -RunRoot $wfRoot -RunId $opt2.runId -Option $fixed.id).steps[2].choice -ceq $fixed.id) 'a choice given with the step is recorded without a decision'
'SUCCESS SUBAGENTS: '+$script:subChecks+' checks; retained fixture '+$root
