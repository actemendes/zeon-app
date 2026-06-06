[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [ValidateSet("split", "universal", "both")]
    [string]$Artifacts = "both",

    [switch]$SkipPubGet
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Get-CoreVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $depFile = Join-Path $RepoRoot "dependencies.properties"
    if (-not (Test-Path -LiteralPath $depFile)) {
        throw "dependencies.properties not found: $depFile"
    }

    $line = Get-Content -LiteralPath $depFile | Where-Object { $_ -match '^core\.version=' } | Select-Object -First 1
    if (-not $line) {
        throw "core.version was not found in dependencies.properties"
    }

    return ($line -split '=')[1].Trim()
}

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

function Ensure-AndroidCoreAar {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $libsDir = Join-Path $RepoRoot "android\app\libs"
    $aarPath = Join-Path $libsDir "hiddify-core.aar"
    if (Test-Path -LiteralPath $aarPath) {
        Write-Host "Android core library found: $aarPath"
        return
    }

    $coreVersion = Get-CoreVersion -RepoRoot $RepoRoot
    $url = "https://github.com/hiddify/hiddify-core/releases/download/v$coreVersion/hiddify-lib-android.tar.gz"
    $archivePath = Join-Path $env:TEMP ("hiddify-lib-android-$coreVersion.tar.gz")

    Write-Host "Downloading Android core library: $url"
    Invoke-WebRequest -Uri $url -OutFile $archivePath

    New-Item -ItemType Directory -Force -Path $libsDir | Out-Null
    tar -xzf $archivePath -C $libsDir

    if (-not (Test-Path -LiteralPath $aarPath)) {
        throw "hiddify-core.aar is still missing after extraction: $aarPath"
    }

    Write-Host "Android core library ready: $aarPath"
}

function Copy-AndroidInstallersToOut {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Artifacts,
        [Parameter(Mandatory = $true)][string]$BuildMode,
        [Parameter(Mandatory = $true)][string]$AppVersion
    )

    $apkDir = Join-Path $RepoRoot "build\app\outputs\flutter-apk"
    if (-not (Test-Path -LiteralPath $apkDir)) {
        throw "APK output directory not found: $apkDir"
    }

    $outDir = Join-Path $RepoRoot "out\installers\android"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $modeSuffix = if ($BuildMode -eq "release") { "" } else { "-$BuildMode" }
    $copies = @()
    if ($Artifacts -in @("split", "both")) {
        $copies += @(
            [pscustomobject]@{ Source = "app-armeabi-v7a-$BuildMode.apk"; Destination = "ZEON-$AppVersion-armeabi-v7a$modeSuffix.apk" },
            [pscustomobject]@{ Source = "app-arm64-v8a-$BuildMode.apk"; Destination = "ZEON-$AppVersion-arm64-v8a$modeSuffix.apk" },
            [pscustomobject]@{ Source = "app-x86_64-$BuildMode.apk"; Destination = "ZEON-$AppVersion-x86_64$modeSuffix.apk" }
        )
    }
    if ($Artifacts -in @("universal", "both")) {
        $copies += [pscustomobject]@{ Source = "app-$BuildMode.apk"; Destination = "ZEON-$AppVersion$modeSuffix.apk" }
    }

    foreach ($copy in $copies) {
        $sourcePath = Join-Path $apkDir $copy.Source
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Expected APK was not found: $sourcePath"
        }

        $legacyPath = Join-Path $outDir $copy.Source
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Force
        }

        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $outDir $copy.Destination) -Force
    }

    Write-Host ""
    Write-Host "Android installers copied to: $outDir"
    Get-ChildItem -LiteralPath $outDir -Filter "*.apk" |
        Sort-Object LastWriteTime -Descending |
        Select-Object Name, Length, LastWriteTime |
        Format-Table -AutoSize
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir

Push-Location $repoRoot
$previousGradleOpts = $env:GRADLE_OPTS
$gradlePackagingOpts = "-Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false"
$env:GRADLE_OPTS = (@($previousGradleOpts, $gradlePackagingOpts) | Where-Object { $_ }) -join " "
try {
    Assert-Command "flutter"
    Assert-Command "dart"
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $BuildTarget))) {
        throw "Build target not found: $BuildTarget"
    }

    Ensure-AndroidCoreAar -RepoRoot $repoRoot
    $appVersion = ConvertTo-ArtifactVersion -Version (Get-PubspecVersion -RepoRoot $repoRoot)

    if (-not $SkipPubGet) {
        Write-Host "Running: flutter pub get"
        & flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "flutter pub get failed."
        }
    }

    Write-Host "Running: dart run slang"
    & dart run slang
    if ($LASTEXITCODE -ne 0) {
        throw "Translation generation failed."
    }

    if ($Artifacts -in @("split", "both")) {
        $splitArgs = @("build", "apk", "--$BuildMode", "--target", $BuildTarget, "--split-per-abi")
        Write-Host ("Running: flutter " + ($splitArgs -join " "))
        & flutter @splitArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Split-per-ABI APK build failed."
        }
    }

    if ($Artifacts -in @("universal", "both")) {
        $universalArgs = @("build", "apk", "--$BuildMode", "--target", $BuildTarget, "--target-platform", "android-arm64")
        Write-Host ("Running: flutter " + ($universalArgs -join " "))
        & flutter @universalArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Universal APK build failed."
        }
    }

    $apkDir = Join-Path $repoRoot "build\app\outputs\flutter-apk"
    if (Test-Path -LiteralPath $apkDir) {
        Write-Host ""
        Write-Host "Generated APK files:"
        Get-ChildItem -LiteralPath $apkDir -Filter "*.apk" |
            Sort-Object LastWriteTime -Descending |
            Select-Object Name, Length, LastWriteTime |
            Format-Table -AutoSize
    }

    Copy-AndroidInstallersToOut -RepoRoot $repoRoot -Artifacts $Artifacts -BuildMode $BuildMode -AppVersion $appVersion
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

