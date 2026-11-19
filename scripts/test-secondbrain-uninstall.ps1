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
Assert-Un (@($data.inventory.keep|Where-Object kind -eq 'mcp-config').Count -eq 1 -and @($data.inventory.keep|Where-Object kind -eq 'shared').Count -eq 1) 'preview lists what stays: MCP configuration and shared'
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
'SUCCESS UNINSTALL: '+$script:unChecks+' checks; retained fixture '+$root
