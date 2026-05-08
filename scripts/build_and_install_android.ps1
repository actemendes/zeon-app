[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$DeviceId,

    [string]$PackageId,

    [switch]$CleanInstall,

    [switch]$Launch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Get-ConnectedDeviceIds {
    $adbOutput = & adb devices
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query connected Android devices via adb."
    }

    return @(
        $adbOutput |
            Select-Object -Skip 1 |
            Where-Object { $_ -match '^\S+\s+device$' } |
            ForEach-Object { ($_ -split '\s+')[0] }
    )
}

function Resolve-DeviceId {
    param([string]$RequestedDeviceId)

    if ($RequestedDeviceId) {
        return $RequestedDeviceId
    }

    $connectedDeviceIds = @(Get-ConnectedDeviceIds)
    switch ($connectedDeviceIds.Count) {
        0 {
            throw "No connected Android devices were found."
        }
        1 {
            return $connectedDeviceIds[0]
        }
        default {
            throw ("More than one Android device is connected. Re-run with -DeviceId. Found: " + ($connectedDeviceIds -join ", "))
        }
    }
}

function Resolve-TargetPlatform {
    param([Parameter(Mandatory = $true)][string]$DeviceAbi)

    switch ($DeviceAbi) {
        "arm64-v8a" {
            return "android-arm64"
        }
        "armeabi-v7a" {
            return "android-arm"
        }
        "x86_64" {
            return "android-x64"
        }
        default {
            throw "Unsupported device ABI '$DeviceAbi'. Update the script mapping before building for this device."
        }
    }
}

function Resolve-ApkPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $expectedApkPath = Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-$Mode.apk"
    if (Test-Path -LiteralPath $expectedApkPath) {
        return $expectedApkPath
    }

    $apkDirectory = Join-Path $RepoRoot "build\app\outputs\flutter-apk"
    if (-not (Test-Path -LiteralPath $apkDirectory)) {
        throw "APK output directory was not found: $apkDirectory"
    }

    $fallbackApk = Get-ChildItem -LiteralPath $apkDirectory -Filter "*.apk" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $fallbackApk) {
        throw "No APK file was found in $apkDirectory"
    }

    return $fallbackApk.FullName
}

function Resolve-AndroidSdkRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $candidates = @()
    if ($env:ANDROID_HOME) { $candidates += $env:ANDROID_HOME }
    if ($env:ANDROID_SDK_ROOT) { $candidates += $env:ANDROID_SDK_ROOT }

    $localPropertiesPath = Join-Path $RepoRoot "android\local.properties"
    if (Test-Path -LiteralPath $localPropertiesPath) {
        $sdkLine = Get-Content -LiteralPath $localPropertiesPath |
            Where-Object { $_ -match '^sdk\.dir=' } |
            Select-Object -First 1
        if ($sdkLine) {
            $sdkDir = ($sdkLine -replace '^sdk\.dir=', '').Replace('\\', '\')
            if ($sdkDir) { $candidates += $sdkDir }
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Android SDK path was not found. Set ANDROID_HOME/ANDROID_SDK_ROOT or android/local.properties sdk.dir."
}

function Resolve-AaptPath {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $aaptCommand = Get-Command "aapt" -ErrorAction SilentlyContinue
    if ($aaptCommand) {
        return $aaptCommand.Source
    }

    $sdkRoot = Resolve-AndroidSdkRoot -RepoRoot $RepoRoot
    $buildToolsDir = Join-Path $sdkRoot "build-tools"
    if (-not (Test-Path -LiteralPath $buildToolsDir)) {
        throw "Android build-tools directory was not found: $buildToolsDir"
    }

    $aapt = Get-ChildItem -LiteralPath $buildToolsDir -Filter "aapt.exe" -Recurse |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if (-not $aapt) {
        throw "aapt.exe was not found under Android SDK build-tools: $buildToolsDir"
    }

    return $aapt.FullName
}

function Resolve-ApkPackageId {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ApkPath
    )

    $aaptPath = Resolve-AaptPath -RepoRoot $RepoRoot
    $badging = & $aaptPath dump badging $ApkPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect APK package id via aapt."
    }

    $packageLine = $badging | Where-Object { $_ -match '^package:' } | Select-Object -First 1
    if ($packageLine -and $packageLine -match "name='([^']+)'") {
        return $Matches[1]
    }

    throw "Failed to parse APK package id from aapt output."
}

function Get-InstalledPackagePath {
    param(
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    return ((& adb -s $DeviceId shell pm path $PackageId 2>$null) | Out-String).Trim()
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir

Push-Location $repoRoot
try {
    Assert-Command "flutter"
    Assert-Command "adb"
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $BuildTarget))) {
        throw "Build target not found: $BuildTarget"
    }

    $resolvedDeviceId = Resolve-DeviceId -RequestedDeviceId $DeviceId
    $deviceState = ((& adb -s $resolvedDeviceId get-state) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $deviceState -ne "device") {
        throw "Device '$resolvedDeviceId' is not ready. Current adb state: '$deviceState'."
    }

    $deviceAbi = ((& adb -s $resolvedDeviceId shell getprop ro.product.cpu.abi) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $deviceAbi) {
        throw "Failed to detect device ABI for '$resolvedDeviceId'."
    }

    $targetPlatform = Resolve-TargetPlatform -DeviceAbi $deviceAbi

    Write-Host "Device ID: $resolvedDeviceId"
    Write-Host "Device ABI: $deviceAbi"
    Write-Host "Target platform: $targetPlatform"
    Write-Host "Build mode: $BuildMode"
    Write-Host "Build target: $BuildTarget"
    Write-Host ""

    $buildArgs = @("build", "apk", "--$BuildMode", "--target", $BuildTarget, "--target-platform", $targetPlatform)
    Write-Host ("Running: flutter " + ($buildArgs -join " "))
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build apk failed."
    }

    $apkPath = Resolve-ApkPath -RepoRoot $repoRoot -Mode $BuildMode
    Write-Host "APK: $apkPath"

    $apkPackageId = Resolve-ApkPackageId -RepoRoot $repoRoot -ApkPath $apkPath
    Write-Host "APK package id: $apkPackageId"

    if ($PackageId) {
        if ($PackageId -ne $apkPackageId) {
            throw "Requested package id '$PackageId' does not match APK package id '$apkPackageId'. Remove -PackageId or pass the APK package id."
        }
        $effectivePackageId = $PackageId
    }
    else {
        $effectivePackageId = $apkPackageId
    }

    if ($CleanInstall) {
        $installedPackagePath = Get-InstalledPackagePath -DeviceId $resolvedDeviceId -PackageId $effectivePackageId
        if ($installedPackagePath) {
            Write-Host "Removing installed package: $effectivePackageId"
            & adb -s $resolvedDeviceId uninstall $effectivePackageId
            if ($LASTEXITCODE -ne 0) {
                throw "adb uninstall failed for package '$effectivePackageId'."
            }
        }
        else {
            Write-Host "Package is not installed, skipping uninstall: $effectivePackageId"
        }

        $installArgs = @("-s", $resolvedDeviceId, "install", $apkPath)
    }
    else {
        $installArgs = @("-s", $resolvedDeviceId, "install", "-r", $apkPath)
    }

    Write-Host ("Running: adb " + ($installArgs -join " "))
    & adb @installArgs
    if ($LASTEXITCODE -ne 0) {
        throw "adb install failed."
    }

    $installedPackagePath = Get-InstalledPackagePath -DeviceId $resolvedDeviceId -PackageId $effectivePackageId
    if (-not $installedPackagePath) {
        throw "adb install returned success, but package '$effectivePackageId' is not installed or not visible to adb."
    }
    Write-Host "Installed package: $effectivePackageId"

    $legacyPackageIds = @("app.hiddify.com")
    foreach ($legacyPackageId in $legacyPackageIds) {
        if ($legacyPackageId -ne $effectivePackageId) {
            $legacyPackagePath = Get-InstalledPackagePath -DeviceId $resolvedDeviceId -PackageId $legacyPackageId
            if ($legacyPackagePath) {
                Write-Warning "Legacy package '$legacyPackageId' is also installed. If you open it manually from launcher, you will test the old app, not '$effectivePackageId'."
            }
        }
    }

    if ($Launch) {
        $launchArgs = @("-s", $resolvedDeviceId, "shell", "monkey", "-p", $effectivePackageId, "-c", "android.intent.category.LAUNCHER", "1")
        Write-Host ("Running: adb " + ($launchArgs -join " "))
        & adb @launchArgs
        if ($LASTEXITCODE -ne 0) {
            throw "App install succeeded, but launch failed for package '$effectivePackageId'."
        }
    }

    Write-Host ""
    Write-Host "Build and install completed successfully."
}
finally {
    Pop-Location
}
