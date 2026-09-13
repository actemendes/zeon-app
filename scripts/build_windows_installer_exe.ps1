[CmdletBinding()]
param(
    [string]$BuildTarget = "lib/main_prod.dart",
    [string]$SentryDsn = "",
    [switch]$AllowUnsignedExe,
    [switch]$UseExistingCertificateOnly,
    [switch]$SkipSecureStoragePatch,
    [switch]$SkipDependencyInstall,
    [switch]$SkipCodeGeneration,
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$innerScript = Join-Path $scriptDir "package_windows_installers.ps1"
. (Join-Path $scriptDir "build\common.ps1")

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    Target      = "exe"
    BuildTarget = $BuildTarget
}

if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($AllowUnsignedExe) { $params.AllowUnsignedExe = $true }
if ($UseExistingCertificateOnly) { $params.UseExistingCertificateOnly = $true }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }

if ($AllowUnsignedExe) {
    Write-Warning "Building an unsigned Windows EXE installer. Do not distribute it as a signed release."
}
else {
    Write-Host "Building signed Windows EXE installer (release/prod)..."
}
Write-Host "Build target: $BuildTarget"

& $innerScript @params

$appVersion = ConvertTo-ZeonArtifactVersion -Version (Get-ZeonAppVersion -RepoRoot $repoRoot)
$outDir = Get-ZeonInstallerPlatformDirectory -RepoRoot $repoRoot -Platform "win"
$sourceName = if ($AllowUnsignedExe) { "ZEON-Windows-Setup-x64-unsigned.exe" } else { "ZEON-Windows-Setup-x64.exe" }
$sourcePath = Join-Path $outDir $sourceName
$destinationName = if ($AllowUnsignedExe) {
    "ZEON-$appVersion-Windows-Setup-x64-unsigned.exe"
}
else {
    "ZEON-$appVersion-Windows-Setup-x64.exe"
}

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Windows EXE installer was not found: $sourcePath"
}

$destinationPath = Publish-ZeonFile -RepoRoot $repoRoot -Platform "win" -SourcePath $sourcePath -DestinationName $destinationName
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourcePath, $destinationPath)) {
    Remove-Item -LiteralPath $sourcePath -Force
}
Write-Host "Versioned Windows EXE installer: $destinationPath"
