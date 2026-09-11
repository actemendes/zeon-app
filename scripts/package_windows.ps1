[CmdletBinding()]
param(
    [ValidateSet("exe", "msix", "all")]
    [string]$Target = "all",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipCodeGeneration,

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
    Target      = $Target
    BuildTarget = $BuildTarget
}

if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }

& $innerScript @params

Write-Host "Done. Final artifacts are under out\installers\win only."
