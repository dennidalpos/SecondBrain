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

# RCTFE card schema (#721, first step): three real cards convert and validate; broken cards are caught.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptSchema.psm1') -Force
$rctfeSchema = Join-Path $PSScriptRoot '../config/prompt-card-rctfe.schema.json'
foreach ($code in 'SYS01', 'AIS01', 'DEV01') {
    $card = ConvertTo-SBRctfeCard (Get-Content -LiteralPath (Join-Path $PSScriptRoot ('../direttive/prompts/' + $code + '.md')) -Raw)
    $problems = @(Test-SBRctfeCard $card $rctfeSchema)
    if ($problems.Count -or $card.code -cne $code -or @($card.task.steps).Count -lt 2) { throw ('FAIL LINT: RCTFE pilot card ' + $code + ' does not validate: ' + ($problems -join ',')) }
}
$broken = ConvertTo-SBRctfeCard (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../direttive/prompts/SYS01.md') -Raw)
$broken.description = 'x' * 121
$broken.task.steps = @('only one')
$brokenProblems = @(Test-SBRctfeCard $broken $rctfeSchema)
if ('schema' -notin $brokenProblems -or 'description' -notin $brokenProblems -or 'steps' -notin $brokenProblems) { throw ('FAIL LINT: a broken RCTFE card was not reported: ' + ($brokenProblems -join ',')) }
Write-Output 'SUCCESS LINT: RCTFE schema validates three pilot cards and rejects a broken one'
