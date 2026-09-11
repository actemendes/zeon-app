[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

$version = Get-ZeonAppVersion -RepoRoot $repoRoot
if ($version -notmatch '^1\.5\.0\+([1-9][0-9]*)$') {
    throw "Windows runtime builds require the canonical 1.5.0+N version in pubspec.yaml. Current: $version"
}

$sourceStatus = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the source working tree." }
if ($sourceStatus.Count -ne 0) {
    throw "Runtime artifacts must be built from a clean committed working tree."
}

$sourceSha = (& git -C $repoRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $sourceSha -notmatch '^[0-9a-f]{40}$') {
    throw "Unable to resolve the source commit SHA."
}
$buildUtc = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
$safeVersion = ConvertTo-ZeonArtifactVersion -Version $version
$suffix = "-runtime-validation"
$folderName = "ZEON-$safeVersion-Windows-$BuildMode-x64$suffix"
$zipName = "ZEON-$safeVersion-Windows-Portable-$BuildMode-x64$suffix.zip"
$platformRoot = Get-ZeonInstallerPlatformDirectory -RepoRoot $repoRoot -Platform "win"
$folderPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot $folderName)
$zipPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot $zipName)
$manifestPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot ($zipName + ".manifest.json"))
$registryPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot "build-registry.jsonl")

foreach ($reservedPath in @($folderPath, $zipPath, $manifestPath)) {
    if (Test-Path -LiteralPath $reservedPath) {
        throw "Build number $version is already represented by an artifact. Increment pubspec.yaml before rebuilding: $reservedPath"
    }
}
if (Test-Path -LiteralPath $registryPath) {
    foreach ($line in Get-Content -LiteralPath $registryPath) {
        if (-not $line.Trim()) { continue }
        $entry = $line | ConvertFrom-Json
        if ($entry.version -eq $version) {
            throw "Build number $version already exists in the build registry. Increment pubspec.yaml before rebuilding."
        }
    }
}

& (Join-Path $scriptDir "build_windows_portable.ps1") `
    -BuildMode $BuildMode `
    -BuildTarget "tool/windows_recovery_runtime.dart" `
    -RuntimeValidation `
    -RuntimeSourceSha $sourceSha `
    -RuntimeBuildUtc $buildUtc `
    -SkipCodeGeneration

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
    throw "Runtime ZIP was not published: $zipPath"
}
$exePath = Join-Path $folderPath "ZEON.exe"
$corePath = Join-Path $folderPath "hiddify-core.dll"
foreach ($required in @($exePath, $corePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Runtime artifact is incomplete: $required"
    }
}

$flutterMachine = (& flutter --version --machine 2>$null | Out-String).Trim() | ConvertFrom-Json
$manifest = [ordered]@{
    schema = "zeon.windows-runtime-build.v1"
    version = $version
    source_sha = $sourceSha
    build_type = "windows-runtime-validation"
    build_mode = $BuildMode
    built_utc = $buildUtc
    flutter_version = $flutterMachine.frameworkVersion
    dart_version = $flutterMachine.dartSdkVersion
    target = "tool/windows_recovery_runtime.dart"
    dart_defines = @(
        "portable=true",
        "zeon_runtime_validation=true",
        "zeon_source_sha=$sourceSha",
        "zeon_build_type=windows-runtime-validation",
        "zeon_build_utc=$buildUtc"
    )
    artifact_path = $zipPath
    artifact_sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    executable_sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
    native_core_sha256 = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash
}

$manifestJson = $manifest | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($manifestPath, $manifestJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Add-Content -LiteralPath $registryPath -Value ($manifest | ConvertTo-Json -Compress -Depth 5) -Encoding utf8

Write-Host "Windows runtime harness published: $zipPath"
Write-Host "Build manifest: $manifestPath"
Write-Host "Source SHA: $sourceSha"
Write-Host "Artifact SHA-256: $($manifest.artifact_sha256)"
