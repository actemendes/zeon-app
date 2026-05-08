[CmdletBinding()]
param(
    [string]$BuildTarget = "lib/main_prod.dart",
    [string]$SentryDsn = "",
    [switch]$UseExistingCertificateOnly,
    [switch]$SkipSecureStoragePatch,
    [switch]$SkipDependencyInstall,
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$innerScript = Join-Path $scriptDir "package_windows_installers.ps1"

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    Target      = "exe"
    BuildTarget = $BuildTarget
}

if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($UseExistingCertificateOnly) { $params.UseExistingCertificateOnly = $true }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
if ($SkipClean) { $params.SkipClean = $true }

Write-Host "Building Windows EXE installer (release/prod)..."
Write-Host "Build target: $BuildTarget"

& $innerScript @params
if ($LASTEXITCODE -ne 0) {
    throw "Windows EXE installer build failed."
}

