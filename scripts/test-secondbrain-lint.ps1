#requires -Version 7.5
# Static analysis gate: scripts/lint.ps1 must match config/lint-baseline.json (no new PSScriptAnalyzer findings).
$ErrorActionPreference='Stop'
if(!(Get-Module -ListAvailable -Name PSScriptAnalyzer)){
    Write-Output 'INFO LINT: modulo PSScriptAnalyzer assente, analisi saltata'
    Write-Output 'SUCCESS LINT: 0 checks (PSScriptAnalyzer not installed)'
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

# RCTFE card schema (#721): a legacy eight-section card converts and validates, renders to the RCTFE card text, and broken cards are caught.
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.PromptSchema.psm1') -Force
$rctfeSchema = Join-Path $PSScriptRoot '../config/prompt-card-rctfe.schema.json'
$legacy = "# ZZZ01 $([char]0x2014) Sample card`n`n<role>`nA tester.`n</role>`n`n<context>`nUse in tests.`n</context>`n`n<inputs>`n- a thing`n</inputs>`n`n<procedure>`n1. First step.`n2. Second step.`n</procedure>`n`n<constraints>`n- Stay small.`n</constraints>`n`n<exit_criteria>`n- It works.`n</exit_criteria>`n`n<output_format>`nA short report.`n</output_format>`n"
$card = ConvertTo-SBRctfeCard $legacy 'user'
$problems = @(Test-SBRctfeCard $card $rctfeSchema)
if ($problems.Count -or $card.code -cne 'ZZZ01' -or @($card.task.steps).Count -ne 2 -or $card.format -notmatch 'Constraints:' -or $card.format -notmatch 'Exit criteria:') { throw ('FAIL LINT: RCTFE legacy conversion does not validate: ' + ($problems -join ',')) }
$cardText = ConvertTo-SBRctfeCardText $card
if ($cardText -notmatch '(?m)^<task>$' -or $cardText -notmatch '(?m)^1\. First step\.$' -or $cardText -match '<procedure>|<inputs>') { throw 'FAIL LINT: RCTFE card text is not in the new layout' }
$broken = ConvertTo-SBRctfeCard $legacy 'user'
$broken.description = 'x' * 121
$broken.task.steps = @('only one')
$brokenProblems = @(Test-SBRctfeCard $broken $rctfeSchema)
if ('schema' -notin $brokenProblems -or 'description' -notin $brokenProblems -or 'steps' -notin $brokenProblems) { throw ('FAIL LINT: a broken RCTFE card was not reported: ' + ($brokenProblems -join ',')) }
Write-Output 'SUCCESS LINT: RCTFE schema converts and validates a legacy card, renders the new layout and rejects a broken one'
