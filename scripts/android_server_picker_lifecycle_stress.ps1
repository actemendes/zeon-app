[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Background", "Network", "Refresh", "Connection")]
    [string]$Scenario,
    [ValidateRange(1, 1000)][int]$Cycles = 20,
    [string]$PackageId = "com.zeon.hiddify.validation",
    [ValidateRange(0, 300)][int]$AwaySeconds = 3,
    [ValidateRange(0, 120)][int]$SettleSeconds = 18,
    [string]$OutputPath = "C:\Temp\zeon-server-picker-lifecycle.jsonl"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Adb {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & adb @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        throw "adb failed ($exitCode): adb $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory = $true)][string]$Value)

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Get-UiXml {
    Invoke-Adb -Arguments @("shell", "uiautomator", "dump", "/sdcard/zeon-picker-lifecycle.xml") | Out-Null
    return [string]::Join("", (Invoke-Adb -Arguments @("shell", "cat", "/sdcard/zeon-picker-lifecycle.xml")))
}

function Invoke-UiLabel {
    param(
        [Parameter(Mandatory = $true)][string]$UiXml,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $match = [regex]::Match(
        $UiXml,
        ('content-desc="' + [regex]::Escape($Label) + '"[^>]*bounds="\[(?<x1>\d+),(?<y1>\d+)\]\[(?<x2>\d+),(?<y2>\d+)\]"')
    )
    if (-not $match.Success) { return $false }
    $x = ([int]$match.Groups["x1"].Value + [int]$match.Groups["x2"].Value) / 2
    $y = ([int]$match.Groups["y1"].Value + [int]$match.Groups["y2"].Value) / 2
    Invoke-Adb -Arguments @("shell", "input", "tap", ([int]$x).ToString(), ([int]$y).ToString()) | Out-Null
    return $true
}

function Start-ValidationApp {
    Invoke-Adb -Arguments @(
        "shell", "monkey", "-p", $PackageId,
        "-c", "android.intent.category.LAUNCHER", "1"
    ) | Out-Null
}

$disconnectLabel = ConvertFrom-Utf8Base64 "0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP"
$connectLabel = ConvertFrom-Utf8Base64 "0J3QsNC20LzQuNGC0LUg0LTQu9GPINC/0L7QtNC60LvRjtGH0LXQvdC40Y8="
$activeServerLabel = ConvertFrom-Utf8Base64 "0JDQutGC0LjQstC90YvQuSDRgdC10YDQstC10YA="
$serversLabel = ConvertFrom-Utf8Base64 "0KHQtdGA0LLQtdGA0LA="
$refreshLabel = ConvertFrom-Utf8Base64 "0J7QsdC90L7QstC40YLRjCDQv9C+0LTQv9C40YHQutGD"
$profileLabel = ConvertFrom-Utf8Base64 "0J7QsdC90L7QstC40YLRjCDQv9C+0LTQv9C40YHQutGD"

$device = (Invoke-Adb -Arguments @("get-state") | Select-Object -First 1).Trim()
if ($device -ne "device") { throw "No ready Android validation device was found." }

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, "", [Text.UTF8Encoding]::new($false))

Start-ValidationApp
Start-Sleep -Seconds 3
$initialUi = Get-UiXml
if (-not $initialUi.Contains($disconnectLabel)) {
    if (-not (Invoke-UiLabel -UiXml $initialUi -Label $connectLabel)) {
        throw "The validation app could not be connected before the stress run."
    }
    Start-Sleep -Seconds $SettleSeconds
}

$airplaneChanged = $false
try {
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        $operationPassed = $true
        switch ($Scenario) {
            "Background" {
                Invoke-Adb -Arguments @("shell", "input", "keyevent", "KEYCODE_HOME") | Out-Null
                Start-Sleep -Seconds $AwaySeconds
                Start-ValidationApp
                Start-Sleep -Seconds 3
            }
            "Network" {
                Invoke-Adb -Arguments @("shell", "cmd", "connectivity", "airplane-mode", "enable") | Out-Null
                $airplaneChanged = $true
                Start-Sleep -Seconds $AwaySeconds
                Invoke-Adb -Arguments @("shell", "cmd", "connectivity", "airplane-mode", "disable") | Out-Null
                $airplaneChanged = $false
                Start-Sleep -Seconds $SettleSeconds
            }
            "Refresh" {
                $ui = Get-UiXml
                $operationPassed = Invoke-UiLabel -UiXml $ui -Label $refreshLabel
                Start-Sleep -Seconds $SettleSeconds
            }
            "Connection" {
                $ui = Get-UiXml
                $operationPassed = Invoke-UiLabel -UiXml $ui -Label $disconnectLabel
                Start-Sleep -Seconds 4
                $ui = Get-UiXml
                $operationPassed = $operationPassed -and (Invoke-UiLabel -UiXml $ui -Label $connectLabel)
                Start-Sleep -Seconds $SettleSeconds
            }
        }

        $ui = Get-UiXml
        $connected = $ui.Contains($disconnectLabel)
        $resolvedPicker = $ui.Contains($activeServerLabel)
        $pickerVisible = $resolvedPicker -or $ui.Contains($serversLabel)
        $record = [ordered]@{
            schema = 1
            scenario = $Scenario
            cycle = $cycle
            captured_at_utc = [DateTime]::UtcNow.ToString("o")
            package = $PackageId
            operation_passed = $operationPassed
            connected = $connected
            picker_visible = $pickerVisible
            picker_resolved = $resolvedPicker
            active_profile_visible = $ui.Contains($profileLabel)
            failure = if (-not $operationPassed) {
                "operation_control_missing"
            } elseif (-not $pickerVisible) {
                "picker_absent"
            } elseif ($Scenario -ne "Network" -and -not $connected) {
                "connection_not_recovered"
            } else {
                $null
            }
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $OutputPath -Encoding UTF8
        $record | ConvertTo-Json -Compress | Write-Output
    }
}
finally {
    if ($airplaneChanged) {
        Invoke-Adb -Arguments @("shell", "cmd", "connectivity", "airplane-mode", "disable") | Out-Null
    }
}
