[CmdletBinding()]
param(
    [ValidateSet("exe", "msix", "all")]
    [string]$Target = "all",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$innerScript = Join-Path $scriptDir "package_windows_installers.ps1"
$repoRoot = Split-Path -Parent $scriptDir

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    Target      = $Target
    BuildTarget = $BuildTarget
}

if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
if ($SkipClean) { $params.SkipClean = $true }

& $innerScript @params
if ($LASTEXITCODE -ne 0) {
    throw "Windows packaging failed."
}

$installerOut = Join-Path $repoRoot "out\installers\win"
$legacyOut = Join-Path $repoRoot "out"
New-Item -ItemType Directory -Force -Path $legacyOut | Out-Null

foreach ($artifact in @("ZEON-Windows-Setup-x64.exe", "ZEON-Windows-Setup-x64.msix")) {
    $source = Join-Path $installerOut $artifact
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $legacyOut $artifact) -Force
    }
}

Remove-Item -Path "$HOME\.pub-cache\git\cache\flutter_circle_flags*" -Force -Recurse -ErrorAction SilentlyContinue

Write-Host "Done"
