#requires -Version 7.5
# Static analysis gate: scripts/lint.ps1 must match config/lint-baseline.json (no new PSScriptAnalyzer findings).
$ErrorActionPreference='Stop'
if(!(Get-Module -ListAvailable -Name PSScriptAnalyzer)){
    Write-Output 'INFO LINT: modulo PSScriptAnalyzer assente, analisi saltata'
    Write-Output 'SUCCESS LINT: 0 verifiche (PSScriptAnalyzer non installato)'
    return
}
$output=@(& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'lint.ps1') 2>&1|ForEach-Object {[string]$_})
if($LASTEXITCODE -ne 0){
    $output|Write-Output
    throw 'FAIL LINT: lint.ps1 ha riportato nuovi riscontri rispetto alla baseline'
}
$output|Write-Output
Write-Output 'SUCCESS LINT: analisi statica conforme alla baseline'

# Renamed scripts: a stale reference must fail, the live tree must pass.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sb-lintrenames-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot 'config'), (Join-Path $fixtureRoot 'docs') | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../config/renamed-scripts.json') -Destination (Join-Path $fixtureRoot 'config/renamed-scripts.json')
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'docs/stale.md') -Value ('Run scripts/' + 'para' + '.ps1 -Check')
    $null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'lint-renames.ps1') -Root $fixtureRoot 2>&1
    if ($LASTEXITCODE -ne 1) { throw 'FAIL LINT: lint-renames.ps1 did not flag the stale reference in the fixture' }
    Write-Output 'SUCCESS LINT: lint-renames flags a stale reference'
}
finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
$null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'lint-renames.ps1') 2>&1 | ForEach-Object { Write-Output ([string]$_) }
if ($LASTEXITCODE -ne 0) { throw 'FAIL LINT: lint-renames.ps1 found stale references in the repository' }
Write-Output 'SUCCESS LINT: no stale references to renamed scripts'
