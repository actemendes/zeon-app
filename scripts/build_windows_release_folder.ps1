[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "debug",

    [string]$BuildTarget = "lib/main_prod.dart",

    [switch]$Launch,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipCodeGeneration,

    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$innerScript = Join-Path $scriptDir "build_and_install_windows.ps1"

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    BuildMode   = $BuildMode
    BuildTarget = $BuildTarget
}

if ($Launch) { $params.Launch = $true }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }

Write-Host "Building Windows app in build\\windows\\x64\\runner\\Release..."
Write-Host "Build target: $BuildTarget"

& $innerScript @params
if ($LASTEXITCODE -ne 0) {
    throw "Windows release folder build failed."
}
