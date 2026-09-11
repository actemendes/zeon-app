[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [switch]$Launch,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipCodeGeneration,

    [switch]$SkipClean,

    [switch]$Portable,

    [switch]$StartupValidation,

    [switch]$RuntimeValidation,

    [string]$RuntimeSourceSha = "",

    [string]$RuntimeBuildUtc = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$innerScript = Join-Path $scriptDir "build_and_install_windows.ps1"
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

if (-not (Test-Path -LiteralPath $innerScript)) {
    throw "Script not found: $innerScript"
}

$params = @{
    BuildMode   = $BuildMode
    BuildTarget = $BuildTarget
}

if ($Launch) { $params.Launch = $true }
if ($SentryDsn) { $params.SentryDsn = $SentryDsn }
if ($SkipSecureStoragePatch) { $params.SkipSecureStoragePatch = $true }
if ($SkipCodeGeneration) { $params.SkipCodeGeneration = $true }
if ($SkipClean) { $params.SkipClean = $true }
if ($Portable) { $params.Portable = $true }
if ($StartupValidation) { $params.StartupValidation = $true }
if ($RuntimeValidation) {
    $params.RuntimeValidation = $true
    $params.RuntimeSourceSha = $RuntimeSourceSha
    $params.RuntimeBuildUtc = $RuntimeBuildUtc
}

Write-Host "Building Windows application folder..."
Write-Host "Build target: $BuildTarget"

& $innerScript @params

$configuration = switch ($BuildMode) {
    "release" { "Release" }
    "profile" { "Profile" }
    "debug" { "Debug" }
}
$sourceDirectory = Join-Path $repoRoot "build\windows\x64\runner\$configuration"
$version = ConvertTo-ZeonArtifactVersion -Version (Get-ZeonAppVersion -RepoRoot $repoRoot)
$validationSuffix = if ($StartupValidation) { "-startup-validation" } elseif ($RuntimeValidation) { "-runtime-validation" } else { "" }
$destinationName = "ZEON-$version-Windows-$BuildMode-x64$validationSuffix"
$publishedDirectory = Publish-ZeonDirectory `
    -RepoRoot $repoRoot `
    -Platform "win" `
    -SourcePath $sourceDirectory `
    -DestinationName $destinationName

Write-Host "Windows application folder is ready: $publishedDirectory"
