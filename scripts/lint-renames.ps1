#requires -Version 7.5
<#
.SYNOPSIS
Fails when a live file still cites a renamed script or module.
.DESCRIPTION
Reads config/renamed-scripts.json (old name, new name, historical paths) and scans the text files of the
repository, skipping historical paths, .git, .runtime, node_modules and build output. Read-only.
-Root points the scan at another tree (used by the fixture test). Exit 1 on any stale reference.
#>
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SecondBrain.Messages.psm1')
Add-SBMessages @{
    'lintrenames.stale' = @{ en = 'Stale reference to renamed {0} (now {1}): {2}:{3}' }
    'lintrenames.ok'    = @{ en = 'No stale references to {0} renamed scripts' }
}
if (!$Root) { $Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
$Root = [IO.Path]::GetFullPath($Root)
$configPath = Join-Path $Root 'config/renamed-scripts.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$historical = @($config.historicalPaths)
$skipDirs = '(^|/)(\.git|\.runtime|node_modules|target|dist|history)/'
$extensions = '\.(ps1|psm1|psd1|md|json|txt|rs|ts|tsx|js|yml|yaml|toml|html|css)$'
$found = 0
$relativeFiles = if (Test-Path -LiteralPath (Join-Path $Root '.git')) { @(& git -C $Root ls-files) }
    else { @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') }) }
foreach ($relative in $relativeFiles) {
    $file = [IO.FileInfo](Join-Path $Root $relative)
    if (!$file.Exists) { continue }
    if ($relative -match $skipDirs -or $relative -notmatch $extensions) { continue }
    if ($historical | Where-Object { $relative -eq $_ -or ($_.EndsWith('/') -and $relative.StartsWith($_)) }) { continue }
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($rename in $config.renames) {
        if (!$text.Contains([string]$rename.old, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $lineNumber = 0
        foreach ($line in $text.Split("`n")) {
            $lineNumber++
            if ($line.Contains([string]$rename.old, [StringComparison]::OrdinalIgnoreCase)) {
                $found++
                [Console]::Error.WriteLine((Get-SBMessage 'lintrenames.stale' @($rename.old, $rename.new, $relative, $lineNumber)))
            }
        }
    }
}
if ($found) { exit 1 }
Write-Output (Get-SBMessage 'lintrenames.ok' @(@($config.renames).Count))
