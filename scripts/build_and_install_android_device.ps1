[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$DeviceId,

    [string]$PackageId = "com.actemendes.zeon",

    [switch]$CleanInstall,

    [switch]$Launch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$innerScript = Join-Path $scriptDir "build_and_install_android.ps1"

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    BuildMode   = $BuildMode
    BuildTarget = $BuildTarget
    PackageId   = $PackageId
}

if ($DeviceId) { $params.DeviceId = $DeviceId }
if ($CleanInstall) { $params.CleanInstall = $true }
if ($Launch) { $params.Launch = $true }

Write-Host "Building and installing Android app to connected device..."
Write-Host "Build target: $BuildTarget"

& $innerScript @params
if ($LASTEXITCODE -ne 0) {
    throw "Android build/install script failed."
}

