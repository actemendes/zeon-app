[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$Cycles = 10,

    [ValidateSet('AutoAfterConnected', 'AutoBeforeConnect', 'AutoDuringReconnect')]
    [string]$Scenario = 'AutoAfterConnected',

    [string]$DeviceId = '18bfc103',

    [string]$EvidenceRoot = 'artifacts/android_false_connected/release_manual_auto_repro'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$targetPackage = 'com.zeon.hiddify'
$targetActivity = "$targetPackage/com.zeon.zeon.MainActivity"
$shortcutActivity = "$targetPackage/com.zeon.zeon.ShortcutActivity"
$probeService = 'com.zeon.hiddify.validation.test/test.com.zeon.zeon.bg.VerificationTrafficService'
$uiDumpPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), "zeon_release_repro_$PID.xml")
$resolvedRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
$directory = Join-Path $resolvedRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
New-Item -ItemType Directory -Force -Path $directory | Out-Null

function Invoke-Adb {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
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
    Invoke-Adb shell uiautomator dump /sdcard/zeon_release_repro.xml | Out-Null
    Invoke-Adb pull /sdcard/zeon_release_repro.xml $uiDumpPath | Out-Null
    return [xml](Get-Content -LiteralPath $uiDumpPath -Encoding utf8)
}

function Find-Node {
    param(
        [Parameter(Mandatory = $true)][xml]$Ui,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate
    )

    return @($Ui.SelectNodes('//node[@content-desc!=""]') | Where-Object $Predicate) |
        Select-Object -First 1
}

function Invoke-NodeTap {
    param([Parameter(Mandatory = $true)]$Node)

    $values = @([regex]::Matches([string]$Node.bounds, '\d+') | ForEach-Object { [int]$_.Value })
    if ($values.Count -ne 4) { throw 'invalid accessibility bounds' }
    Invoke-Adb shell input tap ([int](($values[0] + $values[2]) / 2)) ([int](($values[1] + $values[3]) / 2)) | Out-Null
}

function Get-NodeByExactDescription {
    param([Parameter(Mandatory = $true)][xml]$Ui, [Parameter(Mandatory = $true)][string]$Description)
    return Find-Node -Ui $Ui -Predicate { [string]$_.'content-desc' -eq $Description }
}

function Wait-UiNode {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [int]$TimeoutSeconds = 35
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $ui = Get-UiXml
        $node = Find-Node -Ui $ui -Predicate $Predicate
        if ($null -ne $node) { return [pscustomobject]@{ Ui = $ui; Node = $node } }
        $failure = Find-Node -Ui $ui -Predicate {
            $description = [string]$_.'content-desc'
            $description.Contains('nativeStartFailure') -or
                $description.Contains('StartService') -or
                $description.Contains('unknown restart failure')
        }
        if ($null -ne $failure) {
            throw "native startup failure surfaced in UI: $([string]$failure.'content-desc')"
        }
        Start-Sleep -Seconds 2
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "UI state timeout after $TimeoutSeconds seconds"
}

function Get-ValidatedVpn {
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    $marker = "VPN:$targetPackage"
    $index = $connectivity.IndexOf($marker, [StringComparison]::Ordinal)
    if ($index -lt 0) { return $false }
    $start = [Math]::Max(0, $index - 1000)
    $length = [Math]::Min(8000, $connectivity.Length - $start)
    return $connectivity.Substring($start, $length).Contains('IS_VALIDATED')
}

function Test-VpnNetworkPresent {
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    return $connectivity.Contains("VPN:$targetPackage")
}

function Wait-VpnNetworkState {
    param(
        [Parameter(Mandatory = $true)][bool]$Present,
        [int]$TimeoutSeconds = 35
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Test-VpnNetworkPresent) -eq $Present) { return }
        Start-Sleep -Seconds 1
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "VPN network presence did not become '$Present' within $TimeoutSeconds seconds"
}

function Invoke-ShortcutToggle {
    Invoke-Adb shell am start -W -a android.intent.action.MAIN -n $shortcutActivity | Out-Null
    Start-Sleep -Seconds 2
}

function Resume-MainActivity {
    Invoke-Adb shell am start -W -n $targetActivity | Out-Null
    Start-Sleep -Seconds 2
}

function Enter-HomeScreen {
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $ui = Get-UiXml
        $connect = Get-NodeByExactDescription -Ui $ui -Description $connectLabel
        $disconnect = Get-NodeByExactDescription -Ui $ui -Description $disconnectLabel
        if ($null -ne $connect -or $null -ne $disconnect) { return $ui }
        Invoke-Adb shell input keyevent KEYCODE_BACK | Out-Null
        Start-Sleep -Seconds 2
    }
    throw 'unable to return to the ZEON home screen'
}

function Open-ServerPicker {
    $homeUi = Get-UiXml
    $server = Find-Node -Ui $homeUi -Predicate {
        ([string]$_.'content-desc').StartsWith("$activeServerPrefix`n", [StringComparison]::Ordinal)
    }
    if ($null -eq $server) { throw 'active server control is unavailable' }
    Invoke-NodeTap -Node $server
    Start-Sleep -Seconds 2
    return Get-UiXml
}

function Move-PickerToAutoRow {
    param([Parameter(Mandatory = $true)][xml]$Picker)

    $pickerUi = $Picker
    $auto = Find-Node -Ui $pickerUi -Predicate { ([string]$_.'content-desc').Contains("$autoLabel ") }
    for ($scroll = 0; $scroll -lt 24 -and $null -eq $auto; $scroll++) {
        Invoke-Adb shell input swipe 540 450 540 1950 300 | Out-Null
        Start-Sleep -Milliseconds 750
        $pickerUi = Get-UiXml
        $auto = Find-Node -Ui $pickerUi -Predicate { ([string]$_.'content-desc').Contains("$autoLabel ") }
    }
    if ($null -eq $auto) { throw 'Autoselect row is unavailable' }
    return [pscustomobject]@{ Ui = $pickerUi; Auto = $auto }
}

function Select-ManualServer {
    $top = Move-PickerToAutoRow -Picker (Open-ServerPicker)
    $picker = $top.Ui
    $manual = Find-Node -Ui $picker -Predicate {
        $description = [string]$_.'content-desc'
        $description.StartsWith("$countryPrefix`n", [StringComparison]::Ordinal) -and
            -not $description.Contains("$autoLabel ")
    }
    if ($null -eq $manual) { throw 'manual server row is unavailable' }
    Invoke-NodeTap -Node $manual
    Start-Sleep -Seconds 3
    $selectedUi = Get-UiXml
    $selectedManual = Find-Node -Ui $selectedUi -Predicate {
        $_.selected -eq 'true' -and
            -not ([string]$_.'content-desc').Contains("$autoLabel ")
    }
    if ($null -eq $selectedManual) { throw 'manual server row did not become selected' }
    Invoke-Adb shell input keyevent KEYCODE_BACK | Out-Null
    Start-Sleep -Seconds 2
}

function Select-AutoServer {
    param([switch]$SkipHomeAssertion)

    $top = Move-PickerToAutoRow -Picker (Open-ServerPicker)
    Select-AutoOnCurrentPicker -PickerState $top
    Invoke-Adb shell input keyevent KEYCODE_BACK | Out-Null
    Start-Sleep -Seconds 2
    if (-not $SkipHomeAssertion) {
        Assert-AutoSelectedOnHome
    }
}

function Select-AutoOnCurrentPicker {
    param([Parameter(Mandatory = $true)]$PickerState)

    $auto = $PickerState.Auto
    Invoke-NodeTap -Node $auto
    Start-Sleep -Seconds 3
    $selectedUi = Get-UiXml
    $selectedAuto = Find-Node -Ui $selectedUi -Predicate {
        $_.selected -eq 'true' -and ([string]$_.'content-desc').Contains("$autoLabel ")
    }
    if ($null -eq $selectedAuto) { throw 'Autoselect row did not become selected' }
}

function Assert-AutoSelectedOnHome {
    $homeUi = Get-UiXml
    $selectedAuto = Find-Node -Ui $homeUi -Predicate {
        ([string]$_.'content-desc').StartsWith("$activeServerPrefix`n", [StringComparison]::Ordinal) -and
            ([string]$_.'content-desc').Contains("$autoLabel ")
    }
    if ($null -eq $selectedAuto) { throw 'Autoselect was not persisted on the home screen' }
}

function Start-TrafficProbe {
    param([Parameter(Mandatory = $true)][string]$Run)
    Invoke-Adb shell am start-foreground-service -n $probeService --es run $Run | Out-Null
    Start-Sleep -Seconds 12
}

$connectLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0J3QsNC20LzQuNGC0LUg0LTQu9GPINC/0L7QtNC60LvRjtGH0LXQvdC40Y8=')
)
$disconnectLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP')
)
$activeServerPrefix = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0JDQutGC0LjQstC90YvQuSDRgdC10YDQstC10YA=')
)
$countryPrefix = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0KHRgtGA0LDQvdCw')
)
$autoLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0JDQstGC0L7QstGL0LHQvtGA')
)
$homeLabel = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('0JPQu9Cw0LLQvdCw0Y8=')
)

Invoke-Adb shell am start -n $targetActivity | Out-Null
Start-Sleep -Seconds 3
$null = Enter-HomeScreen

$results = [Collections.Generic.List[object]]::new()
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $number = '{0:D2}' -f $cycle
    $cycleLog = Join-Path $directory "cycle-$number-full-logcat.txt"
    $cycleErr = Join-Path $directory "cycle-$number-logcat-stderr.txt"
    $manualRun = "release_repro_${number}_manual"
    $autoRun = "release_repro_${number}_auto"
    $tunPresent = $false
    $vpnValidated = $false
    Invoke-Adb logcat -c | Out-Null
    $logcat = Start-Process adb.exe -ArgumentList @('-s', $DeviceId, 'logcat', '-b', 'all', '-v', 'threadtime') `
        -RedirectStandardOutput $cycleLog -RedirectStandardError $cycleErr -WindowStyle Hidden -PassThru
    $cycleError = ''
    try {
        $homeUi = Enter-HomeScreen
        $initialConnect = Get-NodeByExactDescription -Ui $homeUi -Description $connectLabel
        if ($null -ne $initialConnect) {
            Invoke-NodeTap -Node $initialConnect
        }
        $connected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
        Select-ManualServer
        $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
        Start-TrafficProbe -Run $manualRun

        if ($Scenario -eq 'AutoBeforeConnect') {
            $connected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
            Invoke-NodeTap -Node $connected.Node
            $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $connectLabel }
            Select-AutoServer -SkipHomeAssertion
            $disconnected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $connectLabel }
            Invoke-NodeTap -Node $disconnected.Node
            $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
        }
        elseif ($Scenario -eq 'AutoDuringReconnect') {
            $connected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
            Invoke-NodeTap -Node $connected.Node
            $disconnected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $connectLabel }
            Invoke-NodeTap -Node $disconnected.Node
            Start-Sleep -Milliseconds 250
            $picker = Move-PickerToAutoRow -Picker (Open-ServerPicker)
            Select-AutoOnCurrentPicker -PickerState $picker
            Invoke-Adb shell input keyevent KEYCODE_BACK | Out-Null
            Start-Sleep -Seconds 2
            $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
        }
        else {
            $connected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
            Invoke-NodeTap -Node $connected.Node
            $disconnected = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $connectLabel }
            Invoke-NodeTap -Node $disconnected.Node
            $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
            Select-AutoServer
        }

        Start-TrafficProbe -Run $autoRun
        $null = Wait-UiNode -Predicate { [string]$_.'content-desc' -eq $disconnectLabel }
        $tunPresent = ((Invoke-Adb shell ip address) -join "`n").Contains('tun0')
        $vpnValidated = Get-ValidatedVpn
    }
    catch {
        $cycleError = $_.Exception.Message
        $tunPresent = $false
        $vpnValidated = $false
    }
    finally {
        Stop-Process -Id $logcat.Id -Force -ErrorAction SilentlyContinue
    }

    $log = Get-Content -LiteralPath $cycleLog -Raw -ErrorAction SilentlyContinue
    $nativeFailure = $log -match 'nativeStartFailure|failure_code=StartService|native_failure=StartService|unknown restart failure'
    $manualHttps = $log -match "run=$manualRun target=(cloudflare_speed|apple_captive) event=real_http_pass"
    $autoHttps = $log -match "run=$autoRun target=(cloudflare_speed|apple_captive) event=real_http_pass"
    $proofReady = $log -match 'event=(data_plane_probe|selected_outbound_revalidation_completed).*ready=true'
    $passed = -not $cycleError -and -not $nativeFailure -and $manualHttps -and $autoHttps -and
        $proofReady -and $tunPresent -and $vpnValidated
    $result = [pscustomobject]@{
        cycle = $cycle
        scenario = $Scenario
        native_failure = $nativeFailure
        manual_https = $manualHttps
        auto_https = $autoHttps
        native_proof = $proofReady
        tun = $tunPresent
        vpn_validated = $vpnValidated
        passed = $passed
        error = $cycleError
    }
    $results.Add($result)
    $result | ConvertTo-Json -Compress | Write-Output
    if ($nativeFailure) { break }
}

$results | Export-Csv -LiteralPath (Join-Path $directory 'cycles.csv') -NoTypeInformation -Encoding utf8
$summary = [ordered]@{
    requested = $Cycles
    completed = $results.Count
    passed = @($results | Where-Object passed).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    native_failures = @($results | Where-Object native_failure).Count
    scenario = $Scenario
    package = $targetPackage
    core_ports = '17178/17179'
    evidence_directory = $directory
}
$summary | ConvertTo-Json | Tee-Object -FilePath (Join-Path $directory 'result.json')
if ($summary.failed -gt 0) { throw 'release Manual/Auto reproduction found a failure' }
