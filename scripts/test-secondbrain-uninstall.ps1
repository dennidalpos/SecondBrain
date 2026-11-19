#requires -Version 7.5
# sb uninstall (#727): preview lists items and keeps; apply (launchers, ide-blocks only) removes just SecondBrain's own text. Synthetic data only.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Host.psm1')
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Uninstall.psm1') -Force
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
$script:unChecks=0
function Assert-Un($Condition,[string]$Message){if(!$Condition){throw ('FAIL UNINSTALL: '+$Message)};$script:unChecks++}
# Pure helpers.
$block="<!-- secondbrain:global:begin -->`nmanaged`n<!-- secondbrain:global:end -->"
$mixed="User line 1`n`n$block`n`nUser line 2`n"
Assert-Un ((Get-SBUninstallBlockNames $mixed) -ceq 'global') 'block names detected'
$cleaned=Remove-SBUninstallBlocks $mixed
Assert-Un ($cleaned -match 'User line 1' -and $cleaned -match 'User line 2' -and $cleaned -notmatch 'secondbrain') 'only the managed block is removed'
Assert-Un (!(Remove-SBUninstallBlocks $block)) 'a file made only of the block becomes empty'
Assert-Un (!(Get-SBUninstallBlockNames "plain text without markers").Count) 'plain text has no block'
# MCP entry removal (#736): other servers stay, JSON and TOML.
$mcpJson='{"theme":"dark","mcpServers":{"secondbrain":{"command":"pwsh"},"other":{"command":"node"}},"projects":{"C:/p":{"mcpServers":{"secondbrain":{"command":"x"},"keep":{"command":"y"}}}}}'
$cleanJson=Remove-SBMcpEntry $mcpJson 'x.json'|ConvertFrom-Json
Assert-Un ($cleanJson.theme -ceq 'dark' -and $cleanJson.mcpServers.other.command -ceq 'node' -and !$cleanJson.mcpServers.PSObject.Properties['secondbrain'] -and $cleanJson.projects.'C:/p'.mcpServers.keep.command -ceq 'y' -and !$cleanJson.projects.'C:/p'.mcpServers.PSObject.Properties['secondbrain']) 'JSON: the secondbrain entry goes (also per project), other servers and keys stay'
Assert-Un ($null -eq (Remove-SBMcpEntry '{"mcpServers":{"other":{}}}' 'x.json')) 'JSON without the entry: nothing to remove'
$mcpToml="model = `"x`"`n`n[mcp_servers.other]`ncommand = `"node`"`n`n[mcp_servers.secondbrain]`ncommand = `"pwsh`"`n`n[mcp_servers.secondbrain.tools.check_publication]`napproval_mode = `"prompt`"`n`n[profiles.a]`nname = `"a`"`n"
$cleanToml=Remove-SBMcpEntry $mcpToml 'config.toml'
Assert-Un ($cleanToml -notmatch 'secondbrain' -and $cleanToml -match '\[mcp_servers\.other\]' -and $cleanToml -match '\[profiles\.a\]' -and $cleanToml -match 'model = ') 'TOML: the server and its tool sections go, the rest stays'
# Fixture.
$root=Join-Path (Get-SBTestRoot) ('uninstall-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain=Join-Path $root 'brain';$checkout=Join-Path $root 'checkout';$ideFile=Join-Path $root 'ide/CLAUDE.md'
function Put([string]$base,[string]$rel,[string]$text){$p=Join-Path $base $rel;[IO.Directory]::CreateDirectory((Split-Path $p))|Out-Null;[IO.File]::WriteAllText($p,$text)}
foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain $sub) -Recurse -Force}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain 'VERSION')
Put $brain 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
Put $checkout 'AGENTS.md' "# Product`n`n<!-- secondbrain:repository:begin -->`nrepo block`n<!-- secondbrain:repository:end -->`n"
Put $checkout 'GEMINI.md' "<!-- secondbrain:pointer:begin -->`npointer only`n<!-- secondbrain:pointer:end -->`n"
Put $checkout 'CLAUDE.md' "Own pointer text.`n`n<!-- secondbrain:pointer:begin -->`npointer`n<!-- secondbrain:pointer:end -->`n"
Put $checkout '.secondbrain/run-tasks.ps1' 'custom launcher edited by the user'
Put $root 'ide/CLAUDE.md' "Mine first.`n`n$block`n"
$cfgPath=Get-SBHostConfigPath $brain
$identity='github.com/test/uninstall'
Put $brain ([IO.Path]::GetRelativePath($brain,$cfgPath)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=(Join-Path $brain '.runtime/hosts/fixture');backupRoot=(Join-Path $brain '.runtime/hosts/fixture/backups');localStateBackupRoot=(Join-Path $brain '.runtime/hosts/fixture/state-backups');allowedOwners=@('test');ides=@();bindings=@(@{identity=$identity;path=$checkout;status='managed'})})
Put $brain ([IO.Path]::GetRelativePath($brain,(Join-Path (Split-Path $cfgPath) 'ide-map.json'))) (ConvertTo-SBJson @{schemaVersion=1;ides=@(@{name='Fixture IDE';mode='file';instructions=$ideFile;mcpConfigPath=(Join-Path $root 'ide/mcp.json')})})
$uninstall=Join-Path $brain 'scripts/uninstall.ps1'
function Invoke-Un([string[]]$Arguments){$out=& pwsh -NoProfile -File $uninstall -ConfigPath $cfgPath @Arguments 2>&1|Out-String;@{code=$LASTEXITCODE;out=$out}}
$hashes=@{};foreach($f in @((Join-Path $checkout 'GEMINI.md'),(Join-Path $checkout 'AGENTS.md'),(Join-Path $checkout 'CLAUDE.md'),$ideFile,(Join-Path $checkout '.secondbrain/run-tasks.ps1'))){$hashes[$f]=Get-SBFileHash $f}
$preview=Invoke-Un @()
$data=$preview.out.Substring($preview.out.IndexOf('{'))|ConvertFrom-Json
Assert-Un ($preview.code -eq 0 -and !$data.applied) ('preview runs and applies nothing: '+$preview.out)
Assert-Un (@($data.inventory.remove|Where-Object kind -eq 'repository').Count -eq 1 -and @($data.inventory.remove|Where-Object kind -eq 'managed-block').Count -eq 4) 'preview lists the repository and the four files with managed blocks'
Assert-Un (@($data.inventory.keep|Where-Object kind -eq 'mcp-config').Count -eq 1 -and @($data.inventory.keep|Where-Object kind -eq 'checkout').Count -eq 1) 'preview lists what stays: MCP configuration and the checkout'
Assert-Un (@($data.inventory.remove|Where-Object kind -in @('shared','runtime')).Count -eq 2) 'preview lists the shared and runtime steps as removals'
Assert-Un (@($hashes.Keys|Where-Object {(Get-SBFileHash $_) -cne $hashes[$_]}).Count -eq 0) 'preview changed no file'
$apply=Invoke-Un @('-Apply','-Only','launchers,ide-blocks')
Assert-Un ($apply.code -eq 0) ('apply with launchers and ide-blocks succeeds and leaves no marker: '+$apply.out)
Assert-Un (!(Test-Path -LiteralPath (Join-Path $checkout 'GEMINI.md'))) 'checkout file made only of the block is removed'
Assert-Un (([IO.File]::ReadAllText((Join-Path $checkout 'AGENTS.md'))) -match 'Product' -and ([IO.File]::ReadAllText((Join-Path $checkout 'AGENTS.md'))) -notmatch 'secondbrain') 'AGENTS.md keeps its own text and loses the block'
$pointer=[IO.File]::ReadAllText((Join-Path $checkout 'CLAUDE.md'))
Assert-Un ($pointer -match 'Own pointer text' -and $pointer -notmatch 'secondbrain') 'pointer file keeps user text and loses the block'
$ide=[IO.File]::ReadAllText($ideFile)
Assert-Un ($ide -match 'Mine first' -and $ide -notmatch 'secondbrain') 'IDE file keeps user text and loses the block'
Assert-Un ((Get-SBFileHash (Join-Path $checkout '.secondbrain/run-tasks.ps1')) -ceq $hashes[(Join-Path $checkout '.secondbrain/run-tasks.ps1')]) 'an edited launcher is never removed'
Assert-Un (@(Get-ChildItem -LiteralPath (Join-Path $brain '.runtime/hosts/fixture/backups') -Recurse -File -ErrorAction SilentlyContinue).Count -ge 2) 'backups were written before the changes'
$mcpFile=Join-Path $root 'ide/mcp.json'
Put $root 'ide/mcp.json' $mcpJson
$mcpPreview=Invoke-Un @()
$mcpData=$mcpPreview.out.Substring($mcpPreview.out.IndexOf('{'))|ConvertFrom-Json
Assert-Un (@($mcpData.inventory.remove|Where-Object kind -eq 'mcp-entry').Count -eq 1 -and (Get-SBFileHash $mcpFile) -ceq (Get-SBTextHash $mcpJson)) 'preview lists the MCP entry and changes nothing'
$mcpApply=Invoke-Un @('-Apply','-Only','mcp')
$mcpAfter=[IO.File]::ReadAllText($mcpFile)|ConvertFrom-Json
Assert-Un ($mcpApply.code -eq 0 -and $mcpAfter.mcpServers.other.command -ceq 'node' -and !$mcpAfter.mcpServers.PSObject.Properties['secondbrain'] -and @(Get-ChildItem -LiteralPath (Join-Path $brain '.runtime/hosts/fixture/backups') -Recurse -File).Count -ge 3) ('apply removes only the secondbrain MCP entry after a backup: '+$mcpApply.out)
$denied=Invoke-Un @('-Apply','-Only','data')
Assert-Un ($denied.code -ne 0) 'data removal is refused without -RemoveData and the authorization text'
$deniedShared=Invoke-Un @('-Apply','-Only','shared')
Assert-Un ($deniedShared.code -ne 0) 'shared removal is refused without -RemoveData and the authorization text'
$deniedRuntime=Invoke-Un @('-Apply','-Only','runtime','-RemoveRuntime','-RuntimeAuthorization','yes')
Assert-Un ($deniedRuntime.code -ne 0 -and (Test-Path -LiteralPath (Join-Path $brain '.runtime'))) 'runtime removal is refused without the exact authorization text and removes nothing'
Put $brain 'shared/README.md' 'readme stays'
Put $brain 'shared/notes/a.md' 'shared data'
$sharedApply=Invoke-Un @('-Apply','-Only','shared','-RemoveData','-Authorization','delete dossiers')
Assert-Un ($sharedApply.code -eq 0 -and !(Test-Path -LiteralPath (Join-Path $brain 'shared/notes')) -and (Test-Path -LiteralPath (Join-Path $brain 'shared/README.md'))) ('shared step removes the contents and keeps README: '+$sharedApply.out)
$runtimeApply=Invoke-Un @('-Apply','-Only','runtime','-RemoveRuntime','-RuntimeAuthorization','delete runtime and backups')
$runtimeData=$runtimeApply.out.Substring($runtimeApply.out.IndexOf('{'))|ConvertFrom-Json
Assert-Un ($runtimeApply.code -eq 0 -and !(Test-Path -LiteralPath (Join-Path $brain '.runtime')) -and @($runtimeData.steps|Where-Object {$_.step -eq 'runtime' -and $_.result -eq 'removed'}).Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $brain 'scripts/uninstall.ps1'))) ('runtime step removes .runtime last and leaves the checkout: '+$runtimeApply.out)
# #727: the repositories step on a checkout with a real dossier: the checkout returns to a fresh clone plus TASKS.md, no marker remains.
$root2=Join-Path (Get-SBTestRoot) ('uninstall-full-'+[guid]::NewGuid().ToString('N').Substring(0,12))
$brain2=Join-Path $root2 'brain';$checkout2=Join-Path $root2 'checkout'
foreach($sub in @('scripts','config')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$sub)) -Destination (Join-Path $brain2 $sub) -Recurse -Force}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../VERSION') -Destination (Join-Path $brain2 'VERSION')
Put $brain2 'config/shared.json' (ConvertTo-SBJson @{schemaVersion=1;allowedOwners=@('test');excludedDirectories=@('.git')})
$identity2='github.com/test/uninstall-full'
Put $brain2 'repos/full/repository.json' (ConvertTo-SBJson @{schemaVersion=1;identity=$identity2;tracker=@{location='dossier';path='tracker.json';schemaVersion=1}})
Put $brain2 'repos/full/entity.json' (ConvertTo-SBJson @{schemaVersion=1;id='dossier-full';kind='project';title='full';status='active'})
Put $brain2 'repos/full/brief.md' '# full'
Put $brain2 'repos/full/context.md' '# Context'
Put $brain2 'repos/full/memory.md' '# Memory'
Put $brain2 'repos/full/tracker.json' (ConvertTo-SBJson @{schemaVersion=1;repository=$identity2;history=@();tasks=@(@{id='F-1';seq=1;title='Finished work';status='done';priority='P2'},@{id='F-2';seq=2;title='Open work';status='todo';priority='P1'})})
Put $checkout2 'AGENTS.md' "# Product`n`nOwn text.`n`n<!-- secondbrain:repository:begin -->`nmanaged block`n<!-- secondbrain:repository:end -->`n"
Put $checkout2 'CLAUDE.md' "<!-- secondbrain:pointer:begin -->`npointer only`n<!-- secondbrain:pointer:end -->`n"
Put $checkout2 'src/code.txt' 'product code'
$null=& git -C $checkout2 init -q 2>&1
$null=& git -C $checkout2 -c user.name=t -c user.email=t@example.invalid add -A 2>&1
$null=& git -C $checkout2 -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m seed 2>&1
$cfgPath2=Get-SBHostConfigPath $brain2
Put $brain2 ([IO.Path]::GetRelativePath($brain2,$cfgPath2)) (ConvertTo-SBJson @{schemaVersion=1;mode='portable';workstationId='fixture';runtimeRoot=(Join-Path $brain2 '.runtime/hosts/fixture');backupRoot=(Join-Path $brain2 '.runtime/hosts/fixture/backups');localStateBackupRoot=(Join-Path $brain2 '.runtime/hosts/fixture/state-backups');allowedOwners=@('test');ides=@();bindings=@(@{identity=$identity2;path=$checkout2;status='managed'})})
$full=& pwsh -NoProfile -File (Join-Path $brain2 'scripts/uninstall.ps1') -ConfigPath $cfgPath2 -Apply -Only repositories,launchers,ide-blocks 2>&1|Out-String
$fullCode=$LASTEXITCODE
$fullData=$full.Substring($full.IndexOf('{'))|ConvertFrom-Json
$gitStatus=@(& git -C $checkout2 status --porcelain 2>&1)
Assert-Un (@($fullData.steps|Where-Object {$_.step -eq 'repositories' -and $_.exitCode -eq 0}).Count -eq 1) ('the repositories step offboards the binding: '+$full)
Assert-Un ($fullCode -eq 0 -and @($fullData.residue).Count -eq 0) ('the marker scan finds nothing after the repositories step: '+$full)
Assert-Un (@($gitStatus|Where-Object {$_ -match '^[ MADRCU?!]{2} ' -and $_ -notmatch '^(\?\?|\s?M|\s?D)\s+(TASKS|AGENTS|CLAUDE)\.md\s*$'}).Count -eq 0) ('the checkout differs from the seed only by TASKS.md and the removed blocks: '+($gitStatus -join ' | '))
$tasksFull=[IO.File]::ReadAllText((Join-Path $checkout2 'TASKS.md'))
Assert-Un ($tasksFull -match 'Open work' -and $tasksFull -notmatch 'Finished work') 'TASKS.md keeps only the open task'
Assert-Un (([IO.File]::ReadAllText((Join-Path $checkout2 'AGENTS.md'))) -match 'Own text' -and !(Test-Path -LiteralPath (Join-Path $checkout2 'CLAUDE.md')) -and !(Test-Path -LiteralPath (Join-Path $brain2 'repos/full'))) 'user text kept, pointer-only file and dossier removed'
'SUCCESS UNINSTALL: '+$script:unChecks+' checks; retained fixture '+$root
