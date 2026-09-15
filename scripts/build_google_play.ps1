[CmdletBinding()]
param(
    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [switch]$SkipPubGet,

    [switch]$SkipCodeGeneration
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Assert-GooglePlaySigningConfiguration {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $androidDir = Join-Path $RepoRoot "android"
    $androidAppDir = Join-Path $androidDir "app"
    $propertiesPath = Join-Path $androidDir "key.properties"
    if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf)) {
        throw (
            "Google Play builds require the configured upload keystore in android/key.properties. " +
            "This build never generates or substitutes a signing identity."
        )
    }

    $properties = @{}
    foreach ($line in Get-Content -LiteralPath $propertiesPath) {
        if ($line -match '^\s*([^#!\s][^=]*)\s*=\s*(.*)\s*$') {
            $properties[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    foreach ($requiredKey in @("storeFile", "storePassword", "keyPassword", "keyAlias")) {
        if (-not $properties.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace($properties[$requiredKey])) {
            throw "Google Play signing property '$requiredKey' is missing from android/key.properties."
        }
    }

    $storePath = [System.IO.Path]::GetFullPath((Join-Path $androidAppDir $properties["storeFile"]))
    if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
        throw "Google Play upload keystore was not found at the path configured by android/key.properties."
    }

    Write-Host "Google Play upload signing configuration is present."
}

function Get-CoreVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $depFile = Join-Path $RepoRoot "dependencies.properties"
    $line = Get-Content -LiteralPath $depFile |
        Where-Object { $_ -match '^core\.version=' } |
        Select-Object -First 1
    if (-not $line) {
        throw "core.version was not found in dependencies.properties"
    }
    return ($line -split '=')[1].Trim()
}

function Ensure-AndroidCoreAar {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $libsDir = Join-Path $RepoRoot "android\app\libs"
    $aarPath = Join-Path $libsDir "hiddify-core.aar"
    if (Test-Path -LiteralPath $aarPath -PathType Leaf) {
        Write-Host "Android core library found: $aarPath"
        return
    }

    $coreVersion = Get-CoreVersion -RepoRoot $RepoRoot
    $url = "https://github.com/hiddify/hiddify-core/releases/download/v$coreVersion/hiddify-lib-android.tar.gz"
    $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) "hiddify-lib-android-$coreVersion.tar.gz"

    Write-Host "Downloading Android core library: $url"
    Invoke-WebRequest -Uri $url -OutFile $archivePath
    New-Item -ItemType Directory -Force -Path $libsDir | Out-Null
    tar -xzf $archivePath -C $libsDir

    if (-not (Test-Path -LiteralPath $aarPath -PathType Leaf)) {
        throw "hiddify-core.aar is still missing after extraction: $aarPath"
    }
    Write-Host "Android core library ready: $aarPath"
}

function Invoke-DartCodeGeneration {
    Write-Host "Running: dart run build_runner build --delete-conflicting-outputs"
    & dart run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) {
        throw "Dart code generation failed."
    }
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir "build\common.ps1")

Push-Location $repoRoot
$previousGradleOpts = $env:GRADLE_OPTS
$gradlePackagingOpts = "-Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false"
$env:GRADLE_OPTS = (@($previousGradleOpts, $gradlePackagingOpts) | Where-Object { $_ }) -join " "
try {
    Assert-Command "flutter"
    Assert-Command "dart"
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $BuildTarget) -PathType Leaf)) {
        throw "Build target not found: $BuildTarget"
    }

    Assert-GooglePlaySigningConfiguration -RepoRoot $repoRoot
    Ensure-AndroidCoreAar -RepoRoot $repoRoot

    if (-not $SkipPubGet) {
        Write-Host "Running: flutter pub get"
        & flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "flutter pub get failed."
        }
    }

    if (-not $SkipCodeGeneration) {
        Invoke-DartCodeGeneration
    }

    Write-Host "Running: dart run slang"
    & dart run slang
    if ($LASTEXITCODE -ne 0) {
        throw "Translation generation failed."
    }

    $buildArgs = @(
        "build",
        "appbundle",
        "--release",
        "--target",
        $BuildTarget,
        "--dart-define",
        "release=google-play"
    )
    if ($SentryDsn) {
        $buildArgs += @("--dart-define", "sentry_dsn=$SentryDsn")
    }

    Write-Host "Building Google Play AAB with the store release contract (custom GitHub updates disabled)."
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Google Play AAB build failed."
    }

    $sourcePath = Join-Path $repoRoot "build\app\outputs\bundle\release\app-release.aab"
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Expected Google Play AAB was not found: $sourcePath"
    }

    $appVersion = ConvertTo-ZeonArtifactVersion -Version (Get-ZeonAppVersion -RepoRoot $repoRoot)
    $destinationName = "ZEON-$appVersion-google-play.aab"
    $publishedPath = Publish-ZeonFile `
        -RepoRoot $repoRoot `
        -Platform "android" `
        -SourcePath $sourcePath `
        -DestinationName $destinationName
    $hash = (Get-FileHash -LiteralPath $publishedPath -Algorithm SHA256).Hash

    Write-Host ""
    Write-Host "Google Play artifact: $publishedPath"
    Write-Host "SHA-256: $hash"
}
finally {
    if ($null -eq $previousGradleOpts) {
        Remove-Item Env:\GRADLE_OPTS -ErrorAction SilentlyContinue
    }
    else {
        $env:GRADLE_OPTS = $previousGradleOpts
    }
    Pop-Location
}
