[CmdletBinding()]
param(
    [ValidateRange(1, 1000)][int]$Cycles = 30,
    [string]$PackageId = "com.zeon.hiddify.validation",
    [ValidateRange(0, 60)][int]$LaunchWaitSeconds = 2,
    [ValidateRange(0, 120)][int]$ConnectWaitSeconds = 10,
    [switch]$EnsureConnected,
    [string]$OutputPath = "C:\Temp\zeon-server-picker-stress.jsonl",
    [string]$FailureCaptureDirectory = "C:\Temp\zeon-server-picker-failures"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & adb @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "adb failed ($exitCode): adb $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-UiXml {
    Invoke-Adb -Arguments @("shell", "uiautomator", "dump", "/sdcard/zeon-picker-stress.xml") | Out-Null
    return [string]::Join("", (Invoke-Adb -Arguments @("shell", "cat", "/sdcard/zeon-picker-stress.xml")))
}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

$disconnectLabel = ConvertFrom-Utf8Base64 "0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP"
$connectLabel = ConvertFrom-Utf8Base64 "0J3QsNC20LzQuNGC0LUg0LTQu9GPINC/0L7QtNC60LvRjtGH0LXQvdC40Y8="
$activeServerLabel = ConvertFrom-Utf8Base64 "0JDQutGC0LjQstC90YvQuSDRgdC10YDQstC10YA="
$autoSelectionLabel = ConvertFrom-Utf8Base64 "0JDQstGC0L7QstGL0LHQvtGA"
$refreshSubscriptionLabel = ConvertFrom-Utf8Base64 "0J7QsdC90L7QstC40YLRjCDQv9C+0LTQv9C40YHQutGD"

function Invoke-ConnectIfAvailable {
    param([Parameter(Mandatory = $true)][string]$UiXml)

    if ($UiXml.Contains($disconnectLabel)) { return }
    $match = [regex]::Match(
        $UiXml,
        ('content-desc="' + [regex]::Escape($connectLabel) + '"[^>]*bounds="\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]"')
    )
    if (-not $match.Success) { return }

    $x = ([int]$match.Groups["x1"].Value + [int]$match.Groups["x2"].Value) / 2
    $y = ([int]$match.Groups["y1"].Value + [int]$match.Groups["y2"].Value) / 2
    Invoke-Adb -Arguments @("shell", "input", "tap", ([int]$x).ToString(), ([int]$y).ToString()) | Out-Null
}

$device = (Invoke-Adb -Arguments @("get-state") | Select-Object -First 1).Trim()
if ($device -ne "device") { throw "No ready Android validation device was found." }

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
New-Item -ItemType Directory -Path $FailureCaptureDirectory -Force | Out-Null
Set-Content -LiteralPath $OutputPath -Value "" -Encoding UTF8

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    Invoke-Adb -Arguments @("shell", "am", "force-stop", $PackageId) | Out-Null
    Invoke-Adb -Arguments @(
        "shell", "monkey", "-p", $PackageId,
        "-c", "android.intent.category.LAUNCHER", "1"
    ) | Out-Null
    Start-Sleep -Seconds $LaunchWaitSeconds

    $ui = Get-UiXml
    if ($EnsureConnected) {
        Invoke-ConnectIfAvailable -UiXml $ui
        Start-Sleep -Seconds $ConnectWaitSeconds
        $ui = Get-UiXml
    }

    $connected = $ui.Contains($disconnectLabel)
    $pickerVisible = $ui.Contains($activeServerLabel)
    $record = [ordered]@{
        schema = 1
        cycle = $cycle
        captured_at_utc = [DateTime]::UtcNow.ToString("o")
        package = $PackageId
        connected = $connected
        picker_visible = $pickerVisible
        auto_selection_visible = $ui.Contains($autoSelectionLabel)
        active_profile_visible = $ui.Contains($refreshSubscriptionLabel)
        failure = if ($connected -and -not $pickerVisible) { "connected_picker_absent" } else { $null }
    }
    ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    $record | ConvertTo-Json -Compress | Write-Output

    if ($connected -and -not $pickerVisible) {
        $deviceCapture = "/sdcard/zeon-picker-failure-$cycle.png"
        Invoke-Adb -Arguments @("shell", "screencap", "-p", $deviceCapture) | Out-Null
        Invoke-Adb -Arguments @(
            "pull", $deviceCapture,
            (Join-Path $FailureCaptureDirectory "cycle-$cycle.png")
        ) | Out-Null
    }
}
