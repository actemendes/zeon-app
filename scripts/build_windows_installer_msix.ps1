[CmdletBinding()]
param(
    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [string]$CertificatePassword = $env:ZEON_MSIX_CERTIFICATE_PASSWORD,

    [switch]$UseExistingCertificateOnly,

    [switch]$AllowDevelopmentMsixCertificate,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipCodeGeneration,

    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

$params = @{
    Target = "msix"
    BuildTarget = $BuildTarget
    CertificatePassword = $CertificatePassword
}
if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($UseExistingCertificateOnly) { $params.UseExistingCertificateOnly = $true }
if ($AllowDevelopmentMsixCertificate) { $params.AllowDevelopmentMsixCertificate = $true }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }

& (Join-Path $scriptDir "package_windows_installers.ps1") @params

$outDir = Get-ZeonInstallerPlatformDirectory -RepoRoot $repoRoot -Platform "win"
$sourcePath = Join-Path $outDir "ZEON-Windows-Setup-x64.msix"
$version = ConvertTo-ZeonArtifactVersion -Version (Get-ZeonAppVersion -RepoRoot $repoRoot)
$destinationName = "ZEON-$version-Windows-Setup-x64.msix"
$destinationPath = Publish-ZeonFile -RepoRoot $repoRoot -Platform "win" -SourcePath $sourcePath -DestinationName $destinationName
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourcePath, $destinationPath)) {
    Remove-Item -LiteralPath $sourcePath -Force
}
Write-Host "Versioned Windows MSIX installer: $destinationPath"
