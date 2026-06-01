param(
    [string]$Serial = "",
    [int]$DurationSec = 150,
    [string]$OutputDir = "out/diagnostics",
    [string]$PythonExe = "python",
    [string]$LaunchPackage = ""
)

$ErrorActionPreference = "Stop"

function Resolve-AdbArgs {
    param([string]$SerialValue)
    if ([string]::IsNullOrWhiteSpace($SerialValue)) {
        return @()
    }
    return @("-s", $SerialValue)
}

function Ensure-Adb {
    $adb = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $adb) {
        throw "adb is not available in PATH."
    }
}

function Ensure-Device {
    param([string]$SerialValue)
    $args = Resolve-AdbArgs -SerialValue $SerialValue
    $output = & adb @args get-state 2>$null
    if ($LASTEXITCODE -ne 0 -or $output.Trim() -ne "device") {
        if ([string]::IsNullOrWhiteSpace($SerialValue)) {
            throw "No active adb device. Connect a device and check 'adb devices'."
        }
        throw "Device '$SerialValue' is not in 'device' state."
    }
}

Ensure-Adb
Ensure-Device -SerialValue $Serial

$resolvedOutput = Resolve-Path . | ForEach-Object { Join-Path $_ $OutputDir }
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $resolvedOutput "mobile_flow_log_$ts.txt"
$adbArgs = Resolve-AdbArgs -SerialValue $Serial

Write-Host "Clearing logcat buffer..."
& adb @adbArgs logcat -c
if ($LASTEXITCODE -ne 0) {
    throw "Failed to clear adb logcat buffer."
}

Write-Host "Starting log capture to $logPath"
$cmdText = "adb " + (($adbArgs + @("logcat", "-v", "time")) -join " ")
$captureProc = Start-Process powershell -ArgumentList @("-NoProfile", "-Command", "$cmdText > `"$logPath`"") -PassThru -WindowStyle Hidden

try {
    if (-not [string]::IsNullOrWhiteSpace($LaunchPackage)) {
        Write-Host "Force-stopping and launching package '$LaunchPackage'..."
        & adb @adbArgs shell am force-stop $LaunchPackage
        Start-Sleep -Seconds 1
        & adb @adbArgs shell monkey -p $LaunchPackage -c android.intent.category.LAUNCHER 1 | Out-Null
    }
    Write-Host "Reproduce the profile bind/import flow now. Capturing for $DurationSec seconds..."
    Start-Sleep -Seconds $DurationSec
}
finally {
    if ($captureProc -and -not $captureProc.HasExited) {
        Stop-Process -Id $captureProc.Id -Force
    }
}

Write-Host "Capture finished: $logPath"
Write-Host "Parsing flow timeline..."
& $PythonExe "scripts/diagnostics/parse_mobile_flow_log.py" --input $logPath --output-dir $resolvedOutput
if ($LASTEXITCODE -ne 0) {
    throw "parse_mobile_flow_log.py failed."
}

Write-Host "Done."
