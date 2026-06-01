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

function Get-PubspecVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $pubspecPath = Join-Path $RepoRoot "pubspec.yaml"
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        throw "pubspec.yaml not found: $pubspecPath"
    }

    $line = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*(.+)$" | Select-Object -First 1
    if (-not $line) {
        throw "Could not find 'version' in $pubspecPath"
    }

    return $line.Matches[0].Groups[1].Value.Trim()
}

function ConvertTo-ArtifactVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    return ($Version -replace '[<>:"/\\|?*]', '-')
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
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

$appVersion = ConvertTo-ArtifactVersion -Version (Get-PubspecVersion -RepoRoot $repoRoot)
$outDir = Join-Path $repoRoot "out\installers\win"
$sourcePath = Join-Path $outDir "ZEON-Windows-Setup-x64.exe"
$destinationPath = Join-Path $outDir "ZEON-$appVersion.exe"

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Windows EXE installer was not found: $sourcePath"
}

Move-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
Write-Host "Versioned Windows EXE installer: $destinationPath"
