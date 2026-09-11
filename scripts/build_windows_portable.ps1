[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipCodeGeneration,

    [switch]$SkipClean,

    [switch]$StartupValidation
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

$params = @{
    BuildMode = $BuildMode
    BuildTarget = $BuildTarget
    Portable = $true
}
if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }
if ($StartupValidation) { $params.StartupValidation = $true }

& (Join-Path $scriptDir "build_windows_release_folder.ps1") @params

$version = ConvertTo-ZeonArtifactVersion -Version (Get-ZeonAppVersion -RepoRoot $repoRoot)
$validationSuffix = if ($StartupValidation) { "-startup-validation" } else { "" }
$folderName = "ZEON-$version-Windows-$BuildMode-x64$validationSuffix"
$sourceDirectory = Join-Path (Get-ZeonInstallerPlatformDirectory -RepoRoot $repoRoot -Platform "win") $folderName
$zipName = "ZEON-$version-Windows-Portable-$BuildMode-x64$validationSuffix.zip"
$zipPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path (Split-Path -Parent $sourceDirectory) $zipName)

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -Path (Join-Path $sourceDirectory "*") -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Host "Portable Windows build published: $zipPath"
Write-Host "SHA-256: $hash"
