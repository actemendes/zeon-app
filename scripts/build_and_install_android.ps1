[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$DeviceId,

    [string]$PackageId = "com.actemendes.zeon",

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

    if ($CleanInstall) {
        $installedPackagePath = ((& adb -s $resolvedDeviceId shell pm path $PackageId 2>$null) | Out-String).Trim()
        if ($installedPackagePath) {
            Write-Host "Removing installed package: $PackageId"
            & adb -s $resolvedDeviceId uninstall $PackageId
            if ($LASTEXITCODE -ne 0) {
                throw "adb uninstall failed for package '$PackageId'."
            }
        }
        else {
            Write-Host "Package is not installed, skipping uninstall: $PackageId"
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

    if ($Launch) {
        $launchArgs = @("-s", $resolvedDeviceId, "shell", "monkey", "-p", $PackageId, "-c", "android.intent.category.LAUNCHER", "1")
        Write-Host ("Running: adb " + ($launchArgs -join " "))
        & adb @launchArgs
        if ($LASTEXITCODE -ne 0) {
            throw "App install succeeded, but launch failed for package '$PackageId'."
        }
    }

    Write-Host ""
    Write-Host "Build and install completed successfully."
}
finally {
    Pop-Location
}
