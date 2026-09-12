[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

$version = Get-ZeonAppVersion -RepoRoot $repoRoot
if ($version -notmatch '^1\.5\.0\+([1-9][0-9]*)$') {
    throw "Android runtime builds require the canonical 1.5.0+N version in pubspec.yaml. Current: $version"
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

$safeVersion = ConvertTo-ZeonArtifactVersion -Version $version
$platformRoot = Get-ZeonInstallerPlatformDirectory -RepoRoot $repoRoot -Platform "android"
$appName = "ZEON-$safeVersion-Android-runtime-validation.apk"
$testName = "ZEON-$safeVersion-Android-runtime-validation-androidTest.apk"
$appPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot $appName)
$testPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot $testName)
$manifestPath = Assert-ZeonInstallerPath -RepoRoot $repoRoot -Path (Join-Path $platformRoot ($appName + ".manifest.json"))

foreach ($reservedPath in @($appPath, $testPath, $manifestPath)) {
    if (Test-Path -LiteralPath $reservedPath) {
        throw "Build number $version is already represented by an artifact. Increment pubspec.yaml before rebuilding: $reservedPath"
    }
}

Push-Location $repoRoot
try {
    Write-Host "Running: dart run build_runner build --delete-conflicting-outputs"
    & dart run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) { throw "Dart code generation failed." }

    Write-Host "Running: dart run slang"
    & dart run slang
    if ($LASTEXITCODE -ne 0) { throw "Translation generation failed." }

    $gradle = Join-Path $repoRoot "android\gradlew.bat"
    $androidProject = Join-Path $repoRoot "android"
    $targetPath = Join-Path $repoRoot "lib\main_prod.dart"
    $gradleArgs = @(
        "--project-dir",
        $androidProject,
        ":app:assembleValidation",
        ":app:assembleValidationAndroidTest",
        "-Ptarget=$targetPath",
        "--no-daemon"
    )
    Write-Host ("Running: android\gradlew.bat " + ($gradleArgs -join " "))
    & $gradle @gradleArgs
    if ($LASTEXITCODE -ne 0) { throw "Android validation build failed." }
}
finally {
    Pop-Location
}

$builtApp = Join-Path $repoRoot "build\app\outputs\apk\validation\app-universal-validation.apk"
$builtTest = Join-Path $repoRoot "build\app\outputs\apk\androidTest\validation\app-validation-androidTest.apk"
foreach ($required in @($builtApp, $builtTest)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Android runtime artifact is incomplete: $required"
    }
}

$appPath = Publish-ZeonFile -RepoRoot $repoRoot -Platform "android" -SourcePath $builtApp -DestinationName $appName
$testPath = Publish-ZeonFile -RepoRoot $repoRoot -Platform "android" -SourcePath $builtTest -DestinationName $testName
$flutterMachine = (& flutter --version --machine 2>$null | Out-String).Trim() | ConvertFrom-Json
$manifest = [ordered]@{
    schema = "zeon.android-runtime-build.v1"
    version = $version
    source_sha = $sourceSha
    build_type = "android-runtime-validation"
    built_utc = [DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    flutter_version = $flutterMachine.frameworkVersion
    dart_version = $flutterMachine.dartSdkVersion
    target = "lib/main_prod.dart"
    application_id = "com.zeon.hiddify.validation"
    test_application_id = "com.zeon.hiddify.validation.test"
    artifact_path = $appPath
    artifact_sha256 = (Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash
    test_artifact_path = $testPath
    test_artifact_sha256 = (Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash
}
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)

Write-Host "Android runtime validation artifacts published:"
Write-Host "  $appPath"
Write-Host "  $testPath"
Write-Host "Build manifest: $manifestPath"
Write-Host "Source SHA: $sourceSha"
