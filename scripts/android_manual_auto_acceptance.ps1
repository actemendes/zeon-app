[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$Cycles = 5,

    [string]$DeviceId = "18bfc103",

    [string]$EvidenceRoot = "artifacts/android_false_connected/manual_auto_acceptance"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$targetPackage = "com.zeon.hiddify.validation"
$targetActivity = "$targetPackage/com.zeon.zeon.MainActivity"
$probeService = "com.zeon.hiddify.validation.test/test.com.zeon.zeon.bg.VerificationTrafficService"
$uiDumpPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zeon_manual_auto_$PID.xml")
$resolvedRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
$directory = Join-Path $resolvedRoot (Get-Date -Format "yyyyMMdd_HHmmss")
New-Item -ItemType Directory -Force -Path $directory | Out-Null

function Invoke-Adb {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & adb -s $DeviceId @args 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($exitCode -ne 0) {
        throw "adb failed: $($args -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-UiXml {
    Invoke-Adb shell uiautomator dump /sdcard/zeon_manual_auto.xml | Out-Null
    Invoke-Adb pull /sdcard/zeon_manual_auto.xml $uiDumpPath | Out-Null
    [xml](Get-Content -LiteralPath $uiDumpPath -Encoding utf8)
}

function Invoke-NodeTap {
    param([Parameter(Mandatory = $true)]$Node)

    $values = @([regex]::Matches([string]$Node.bounds, '\d+') | ForEach-Object { [int]$_.Value })
    if ($values.Count -ne 4) { throw "invalid accessibility bounds" }
    Invoke-Adb shell input tap ([int](($values[0] + $values[2]) / 2)) ([int](($values[1] + $values[3]) / 2)) | Out-Null
}

function Get-SafeLog {
    @(
        Invoke-Adb logcat -d -v threadtime |
            Select-String -Pattern 'A/VpnSession|ZEON_VERIFY|ConnectionNotifier'
    )
}

function Get-ValidatedVpn {
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    $marker = "ni{VPN CONNECTED extra: VPN:$targetPackage"
    $index = $connectivity.IndexOf($marker, [StringComparison]::Ordinal)
    if ($index -lt 0) { return $false }
    $length = [Math]::Min(6000, $connectivity.Length - $index)
    return $connectivity.Substring($index, $length).Contains("IS_VALIDATED")
}

function Find-Node {
    param(
        [Parameter(Mandatory = $true)][xml]$Ui,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate
    )

    @($Ui.SelectNodes('//node[@content-desc!=""]') | Where-Object $Predicate) |
        Select-Object -First 1
}

$disconnectLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String("0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP")
)
$activeServerPrefix = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String("0JDQutGC0LjQstC90YvQuSDRgdC10YDQstC10YA=")
)
$countryPrefix = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String("0KHRgtGA0LDQvdCw")
)
$autoLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String("0JDQstGC0L7QstGL0LHQvtGA")
)

Invoke-Adb shell am start -n $targetActivity | Out-Null
Start-Sleep -Seconds 2
$homeUi = Get-UiXml
$connected = Find-Node -Ui $homeUi -Predicate { $_.'content-desc' -eq $disconnectLabel }
if (-not $connected) { throw "acceptance requires an already connected validation VPN" }

$results = [Collections.Generic.List[object]]::new()
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $homeUi = Get-UiXml
    $activeServer = Find-Node -Ui $homeUi -Predicate {
        ([string]$_.'content-desc').StartsWith($activeServerPrefix, [StringComparison]::Ordinal)
    }
    if (-not $activeServer) { throw "cycle ${cycle}: active server control is unavailable" }
    Invoke-NodeTap -Node $activeServer
    Start-Sleep -Seconds 1

    $picker = Get-UiXml
    $manual = Find-Node -Ui $picker -Predicate {
        $description = [string]$_.'content-desc'
        $description.StartsWith("$countryPrefix`n", [StringComparison]::Ordinal) -and
            -not $description.Contains("$autoLabel ")
    }
    if (-not $manual) { throw "cycle ${cycle}: manual server row is unavailable" }

    Invoke-Adb logcat -c | Out-Null
    Invoke-NodeTap -Node $manual
    Start-Sleep -Seconds 5
    $manualLog = Get-SafeLog
    $manualLog | Set-Content -LiteralPath (Join-Path $directory "cycle-$cycle-manual.txt") -Encoding utf8
    $manualReady = @($manualLog | Where-Object {
        $_ -match 'event=selected_outbound_revalidation_completed' -and $_ -match 'ready=true'
    }).Count -gt 0

    $picker = Get-UiXml
    $auto = Find-Node -Ui $picker -Predicate {
        ([string]$_.'content-desc').Contains("$autoLabel ")
    }
    if (-not $auto) { throw "cycle ${cycle}: Autoselect row is unavailable" }

    Invoke-Adb logcat -c | Out-Null
    Invoke-NodeTap -Node $auto
    Start-Sleep -Seconds 7
    $run = "manual_auto_{0:D2}_{1}" -f $cycle, (Get-Date -Format "yyyyMMdd_HHmmss")
    Invoke-Adb shell am start-foreground-service -n $probeService --es run $run | Out-Null
    Start-Sleep -Seconds 12
    $autoLog = Get-SafeLog
    $autoLog | Set-Content -LiteralPath (Join-Path $directory "cycle-$cycle-auto.txt") -Encoding utf8

    $autoReady = @($autoLog | Where-Object {
        $_ -match 'event=selected_outbound_revalidation_completed' -and $_ -match 'ready=true'
    }).Count -gt 0
    $realHttpsPasses = @($autoLog | Where-Object {
        $_ -match "run=$run target=(cloudflare_speed|apple_captive) event=real_http_pass"
    }).Count
    $revalidationFailures = @($manualLog + $autoLog | Where-Object {
        $_ -match 'event=selected_outbound_revalidation_completed' -and $_ -match 'ready=false'
    }).Count

    Invoke-Adb shell input keyevent KEYCODE_BACK | Out-Null
    Start-Sleep -Seconds 1
    $homeUi = Get-UiXml
    $uiConnected = $null -ne (Find-Node -Ui $homeUi -Predicate { $_.'content-desc' -eq $disconnectLabel })
    $vpnValidated = Get-ValidatedVpn
    $passed = $manualReady -and $autoReady -and $realHttpsPasses -ge 1 -and
        $revalidationFailures -eq 0 -and $uiConnected -and $vpnValidated

    $result = [pscustomobject]@{
        cycle = $cycle
        manual_revalidated = $manualReady
        auto_revalidated = $autoReady
        real_https_passes = $realHttpsPasses
        revalidation_failures = $revalidationFailures
        ui_connected = $uiConnected
        vpn_validated = $vpnValidated
        passed = $passed
    }
    $results.Add($result)
    $result | ConvertTo-Json -Compress | Write-Output
}

$results | Export-Csv -LiteralPath (Join-Path $directory "cycles.csv") -NoTypeInformation -Encoding utf8
$summary = [ordered]@{
    requested = $Cycles
    completed = $results.Count
    passed = @($results | Where-Object passed).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    false_connected = @($results | Where-Object {
        $_.ui_connected -and ($_.real_https_passes -lt 1 -or -not $_.vpn_validated)
    }).Count
    evidence_directory = $directory
}
$summary | ConvertTo-Json | Tee-Object -FilePath (Join-Path $directory "result.json")
if ($summary.failed -gt 0) { throw "manual -> Autoselect acceptance failed" }
