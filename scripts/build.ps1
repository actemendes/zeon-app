[CmdletBinding()]
param(
    [ValidateSet(
        "help",
        "windows-folder",
        "windows-portable",
        "windows-exe",
        "windows-exe-unsigned",
        "windows-msix",
        "windows-run",
        "windows-runtime",
        "android-apk",
        "android-apks",
        "android-google-play",
        "android-runtime",
        "android-debug-install",
        "android-release-install"
    )]
    [string]$Action = "help",

    [ValidateSet("release", "debug", "profile")]
    [string]$Mode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [string]$DeviceId,

    [string]$AndroidRuntimeApplicationIdSuffix = ".validation",

    [string]$AndroidRuntimeArtifactLabel = "",

    [ValidateSet("tool/android_recovery_runtime.dart", "lib/main_prod.dart")]
    [string]$AndroidRuntimeBuildTarget = "tool/android_recovery_runtime.dart",

    [switch]$CleanInstall,

    [switch]$Launch,

    [switch]$AllowUnsignedExe,

    [switch]$UseExistingCertificateOnly,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipCodeGeneration,

    [switch]$SkipClean,

    [switch]$StartupValidation,

    [Alias("List")]
    [switch]$ListActions
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

$actions = @(
    [pscustomobject]@{ Action = "windows-folder"; Result = "Unpacked Windows folder in out/installers/win" },
    [pscustomobject]@{ Action = "windows-portable"; Result = "Portable Windows ZIP in out/installers/win" },
    [pscustomobject]@{ Action = "windows-exe"; Result = "Signed Windows EXE installer in out/installers/win" },
    [pscustomobject]@{ Action = "windows-exe-unsigned"; Result = "Unsigned Windows EXE installer in out/installers/win" },
    [pscustomobject]@{ Action = "windows-msix"; Result = "Windows MSIX installer in out/installers/win" },
    [pscustomobject]@{ Action = "windows-run"; Result = "Debug Windows build, published folder, and optional launch" },
    [pscustomobject]@{ Action = "windows-runtime"; Result = "Headless Windows runtime harness ZIP and provenance manifest" },
    [pscustomobject]@{ Action = "android-apk"; Result = "Universal APK in out/installers/android" },
    [pscustomobject]@{ Action = "android-apks"; Result = "Universal and per-ABI APKs in out/installers/android" },
    [pscustomobject]@{ Action = "android-google-play"; Result = "Signed Google Play AAB in out/installers/android; GitHub updates disabled" },
    [pscustomobject]@{ Action = "android-runtime"; Result = "Isolated Android validation APKs and provenance manifest" },
    [pscustomobject]@{ Action = "android-debug-install"; Result = "Debug APK in out/installers/android and install via ADB" },
    [pscustomobject]@{ Action = "android-release-install"; Result = "Release APK in out/installers/android and install via ADB" }
)

if ($ListActions -or $Action -eq "help") {
    Write-Host "ZEON application build entrypoint"
    Write-Host "Usage: .\scripts\build.ps1 -Action <name> [options]"
    Write-Host ""
    $actions | Format-Table -AutoSize
    Write-Host "All final artifacts are published only below:"
    Write-Host (Join-Path $repoRoot "out\installers")
    return
}

function Add-CommonWindowsParameters {
    param([hashtable]$Parameters)

    $Parameters.BuildTarget = $BuildTarget
    if ($SentryDsn) { $Parameters.SentryDsn = $SentryDsn }
    if ($SkipSecureStoragePatch) { $Parameters.SkipSecureStoragePatch = $true }
    if ($SkipCodeGeneration) { $Parameters.SkipCodeGeneration = $true }
    if ($SkipClean) { $Parameters.SkipClean = $true }
    if ($StartupValidation) { $Parameters.StartupValidation = $true }
    return $Parameters
}

$previousPath = $env:PATH
Use-ZeonPinnedFlutter -RepoRoot $repoRoot | Out-Null
Push-Location $repoRoot
try {
    switch ($Action) {
        "windows-folder" {
            $params = Add-CommonWindowsParameters -Parameters @{ BuildMode = $Mode }
            if ($Launch) { $params.Launch = $true }
            & (Join-Path $scriptDir "build_windows_release_folder.ps1") @params
        }
        "windows-portable" {
            $params = Add-CommonWindowsParameters -Parameters @{ BuildMode = $Mode }
            & (Join-Path $scriptDir "build_windows_portable.ps1") @params
        }
        "windows-exe" {
            $params = Add-CommonWindowsParameters -Parameters @{}
            [void]$params.Remove("StartupValidation")
            if ($AllowUnsignedExe) { $params.AllowUnsignedExe = $true }
            if ($UseExistingCertificateOnly) { $params.UseExistingCertificateOnly = $true }
            if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
            & (Join-Path $scriptDir "build_windows_installer_exe.ps1") @params
        }
        "windows-exe-unsigned" {
            $params = Add-CommonWindowsParameters -Parameters @{ AllowUnsignedExe = $true }
            [void]$params.Remove("StartupValidation")
            if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
            & (Join-Path $scriptDir "build_windows_installer_exe.ps1") @params
        }
        "windows-msix" {
            $params = @{ BuildTarget = $BuildTarget }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($UseExistingCertificateOnly) { $params.UseExistingCertificateOnly = $true }
            if ($SkipDependencyInstall) { $params.SkipDependencyInstall = $true }
            if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
            if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
            if ($SkipClean) { $params.SkipClean = $true }
            & (Join-Path $scriptDir "build_windows_installer_msix.ps1") @params
        }
        "windows-run" {
            $params = Add-CommonWindowsParameters -Parameters @{ BuildMode = "debug" }
            $params.Launch = $true
            & (Join-Path $scriptDir "build_windows_release_folder.ps1") @params
        }
        "windows-runtime" {
            & (Join-Path $scriptDir "build_windows_runtime.ps1") -BuildMode $Mode
        }
        "android-apk" {
            $params = @{
                BuildMode = $Mode
                BuildTarget = $BuildTarget
                Artifacts = "universal"
            }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
            & (Join-Path $scriptDir "build_android_installation_apks.ps1") @params
        }
        "android-apks" {
            $params = @{
                BuildMode = $Mode
                BuildTarget = $BuildTarget
                Artifacts = "both"
            }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
            & (Join-Path $scriptDir "build_android_installation_apks.ps1") @params
        }
        "android-google-play" {
            $params = @{ BuildTarget = $BuildTarget }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
            & (Join-Path $scriptDir "build_google_play.ps1") @params
        }
        "android-runtime" {
            & (Join-Path $scriptDir "build_android_runtime.ps1") `
                -ApplicationIdSuffix $AndroidRuntimeApplicationIdSuffix `
                -ArtifactLabel $AndroidRuntimeArtifactLabel `
                -BuildTarget $AndroidRuntimeBuildTarget
        }
        "android-debug-install" {
            $params = @{ BuildMode = "debug"; BuildTarget = $BuildTarget }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($DeviceId) { $params.DeviceId = $DeviceId }
            if ($CleanInstall) { $params.CleanInstall = $true }
            if ($Launch) { $params.Launch = $true }
            & (Join-Path $scriptDir "build_and_install_android.ps1") @params
        }
        "android-release-install" {
            $params = @{ BuildMode = "release"; BuildTarget = $BuildTarget }
            if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
            if ($DeviceId) { $params.DeviceId = $DeviceId }
            if ($CleanInstall) { $params.CleanInstall = $true }
            if ($Launch) { $params.Launch = $true }
            & (Join-Path $scriptDir "build_and_install_android.ps1") @params
        }
    }
}
finally {
    Pop-Location
    $env:PATH = $previousPath
}
