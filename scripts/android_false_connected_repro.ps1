[CmdletBinding()]
param(
    [ValidateRange(1, 200)]
    [int]$Cycles = 30,

    [ValidateRange(1, 10)]
    [int]$ProbeRepetitions = 2,

    [ValidateSet("https", "socket_download_ipv4", "socket_upload_ipv4", "matrix")]
    [string]$Scenario = "socket_download_ipv4",

    [ValidateRange(5, 45)]
    [int]$ProbeDeadlineSeconds = 18,

    [string]$DeviceId = "",

    [string]$TargetPackage = "com.zeon.hiddify.validation",

    [string]$ProbePackage = "com.zeon.hiddify.validation.test",

    [string]$EvidenceRoot = "artifacts/android_false_connected"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$adbPrefix = @()
if ($DeviceId) {
    $adbPrefix = @("-s", $DeviceId)
}

function Invoke-Adb {
    & adb @adbPrefix @args
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed: $($args -join ' ')"
    }
}

function Get-UiXml {
    Invoke-Adb shell uiautomator dump /sdcard/zeon_false_connected_ui.xml 2>$null | Out-Null
    return (Invoke-Adb shell cat /sdcard/zeon_false_connected_ui.xml) -join "`n"
}

function Get-UiPhase {
    param([Parameter(Mandatory = $true)][string]$Xml)
    # Keep the script ASCII-only so Windows PowerShell 5.1 does not reinterpret
    # Russian semantics labels when the file has UTF-8 encoding without a BOM.
    $disconnectAction = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP")
    )
    $connectAction = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J3QsNC20LzQuNGC0LUg0LTQu9GPINC/0L7QtNC60LvRjtGH0LXQvdC40Y8=")
    )
    $cancelAction = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J7RgtC80LXQvdC40YLRjA==")
    )
    $connecting = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J/QvtC00LrQu9GO0YfQtdC90LjQtQ==")
    )
    $cancelSuffix = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0LTQu9GPINC+0YLQvNC10L3Riw==")
    )
    if ($Xml.Contains($disconnectAction)) { return "CONNECTED" }
    if ($Xml.Contains($connectAction)) { return "DISCONNECTED" }
    if ($Xml.Contains($cancelAction) -or $Xml.Contains($connecting) -or $Xml.Contains($cancelSuffix)) {
        return "CONNECTING"
    }
    return "UNKNOWN"
}

function Wait-UiPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 400
        $xml = Get-UiXml
        $phase = Get-UiPhase -Xml $xml
        if ($phase -eq $Expected) {
            return @{ phase = $phase; xml = $xml; at = (Get-Date) }
        }
    } while ((Get-Date) -lt $deadline)
    return @{ phase = $phase; xml = $xml; at = (Get-Date) }
}

function Get-VpnState {
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    $vpnMarker = "ni{VPN CONNECTED extra: VPN:$TargetPackage"
    $vpnIndex = $connectivity.IndexOf($vpnMarker, [StringComparison]::Ordinal)
    $active = $vpnIndex -ge 0
    $vpnBlock = ""
    if ($active) {
        # The VPN marker sits inside one NetworkAgentInfo entry.  Starting at
        # that marker avoids an accidental cross-entry regex match and is
        # sufficient for the nearby capabilities/link-properties fields.
        $length = [Math]::Min(6000, $connectivity.Length - $vpnIndex)
        $vpnBlock = $connectivity.Substring($vpnIndex, $length)
    }
    $interface = ""
    if ($vpnBlock -match 'InterfaceName: (tun\d+)') {
        $interface = $Matches[1]
    }
    $validated = $active -and $vpnBlock.Contains("IS_VALIDATED")
    return @{ active = $active; validated = $validated; interface = $interface }
}

function Get-TunCounters {
    param([string]$Interface = "")
    $pattern = if ($Interface) { '^\s*' + [regex]::Escape($Interface) + ':' } else { '^\s*tun\d+:' }
    $line = (Invoke-Adb shell cat /proc/net/dev | Select-String -Pattern $pattern) | Select-Object -First 1
    if (-not $line) {
        return @{ interface = ""; rx = 0L; tx = 0L; raw = "" }
    }
    $raw = $line.Line.Trim()
    if ($raw -notmatch '^(tun\d+):\s+(\d+)\s+(?:\d+\s+){7}(\d+)') {
        return @{ interface = ""; rx = 0L; tx = 0L; raw = $raw }
    }
    return @{ interface = $Matches[1]; rx = [long]$Matches[2]; tx = [long]$Matches[3]; raw = $raw }
}

function Save-FailureEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Run,
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    $Xml | Set-Content -LiteralPath (Join-Path $Directory "$Run-ui.xml") -Encoding utf8
    (Invoke-Adb shell date) | Set-Content -LiteralPath (Join-Path $Directory "$Run-device-time.txt") -Encoding utf8
    (Invoke-Adb shell ip -br addr) | Set-Content -LiteralPath (Join-Path $Directory "$Run-addresses.txt") -Encoding utf8
    (Invoke-Adb shell ip route show table all) | Set-Content -LiteralPath (Join-Path $Directory "$Run-routes.txt") -Encoding utf8
    (Invoke-Adb shell cat /proc/net/dev) | Set-Content -LiteralPath (Join-Path $Directory "$Run-net-dev.txt") -Encoding utf8
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    $vpnMarker = "ni{VPN CONNECTED extra: VPN:$TargetPackage"
    $vpnIndex = $connectivity.IndexOf($vpnMarker, [StringComparison]::Ordinal)
    $safeConnectivity = @("vpn_marker_present=$($vpnIndex -ge 0)")
    if ($vpnIndex -ge 0) {
        $length = [Math]::Min(6000, $connectivity.Length - $vpnIndex)
        $vpnFragment = $connectivity.Substring($vpnIndex, $length)
        $safeConnectivity += $vpnFragment -split "`n" |
            Select-String -Pattern '^ni\{VPN CONNECTED|TRANSPORT_VPN|InterfaceName: tun|DnsAddresses:|Routes:|UnderlyingNetworks|IS_VALIDATED'
    }
    $safeConnectivity |
        Set-Content -LiteralPath (Join-Path $Directory "$Run-connectivity.txt") -Encoding utf8
    (Invoke-Adb logcat -d -v threadtime |
        Select-String -Pattern 'A/VpnSession|ConnectionNotifier|ZEON_DP|ZEON_REPRO|server_picker_model') |
        Select-Object -Last 2500 |
        Set-Content -LiteralPath (Join-Path $Directory "$Run-correlated-log.txt") -Encoding utf8
}

$resolvedRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
$runDirectory = Join-Path $resolvedRoot (Get-Date -Format "yyyyMMdd_HHmmss")
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

$targetActivity = "$TargetPackage/com.zeon.zeon.MainActivity"
$probeActivity = if ($Scenario -eq "matrix") {
    "$ProbePackage/test.com.zeon.zeon.bg.GlobalDataPlaneMatrixActivity"
} else {
    "$ProbePackage/test.com.zeon.zeon.bg.DataPlaneValidationActivity"
}
$probeLogTags = if ($Scenario -eq "matrix") { @('ZEON_MATRIX:V', '*:S') } else { @('ZEON_DP:V', '*:S') }
$expectedSuccesses = if ($Scenario -eq "matrix") { 4 } else { $ProbeRepetitions }
$summary = [System.Collections.Generic.List[object]]::new()
$falseConnected = 0
$startupRejected = 0

Invoke-Adb shell am start -n $targetActivity | Out-Null

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $run = "reconnect_{0:D3}_{1}" -f $cycle, (Get-Date -Format "yyyyMMdd_HHmmss")

    $xml = Get-UiXml
    $phase = Get-UiPhase -Xml $xml
    if ($phase -eq "CONNECTED") {
        Invoke-Adb shell input tap 540 974 | Out-Null
        $stopped = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 35
        if ($stopped.phase -ne "DISCONNECTED") {
            throw "cycle ${cycle}: disconnect did not complete (phase=$($stopped.phase))"
        }
    } elseif ($phase -ne "DISCONNECTED") {
        $stopped = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 35
        if ($stopped.phase -ne "DISCONNECTED") {
            throw "cycle ${cycle}: expected disconnected baseline (phase=$($stopped.phase))"
        }
    }

    # Scope structured gate logs to this connect attempt. This lets the
    # harness distinguish a safe data-plane rejection from a hung startup.
    Invoke-Adb logcat -c | Out-Null
    Invoke-Adb shell log -t ZEON_REPRO "run=$run event=cycle_start" | Out-Null
    $startAt = Get-Date
    Invoke-Adb shell input tap 540 974 | Out-Null
    $connectDeadline = (Get-Date).AddSeconds(50)
    $gateRejected = $false
    do {
        Start-Sleep -Milliseconds 400
        $connectXml = Get-UiXml
        $connectPhase = Get-UiPhase -Xml $connectXml
        if ($connectPhase -eq "CONNECTED") { break }
        $gateRejected = @(
            Invoke-Adb logcat -d -v brief -s 'A/VpnSession:I' '*:S' |
                Select-String -Pattern 'event=start_gate_rejected'
        ).Count -gt 0
        if ($gateRejected) { break }
    } while ((Get-Date) -lt $connectDeadline)
    $connected = @{ phase = $connectPhase; xml = $connectXml; at = (Get-Date) }
    if ($gateRejected) {
        $startupRejected++
        $gateLines = Invoke-Adb logcat -d -v threadtime |
            Select-String -Pattern 'data_plane_probe_completed|start_gate_rejected|vpn_snapshot.*phase=(FAILED|DISCONNECTED)'
        $gateLines | Set-Content -LiteralPath (Join-Path $runDirectory "$run-gate-log.txt") -Encoding utf8
        $item = [pscustomobject]@{
            cycle = $cycle
            run = $run
            connected_ms = 0
            startup_rejected = $true
            ui_connected = $false
            probe_successes = 0
            probe_failures = 0
            probe_timed_out = $false
            vpn_active = $false
            vpn_validated = $false
            tun_interface = ""
            tun_rx_delta = 0
            tun_tx_delta = 0
            false_connected = $false
        }
        $summary.Add($item)
        $item | ConvertTo-Json -Compress | Write-Output
        $summary | Export-Csv -LiteralPath (Join-Path $runDirectory "summary.csv") -NoTypeInformation -Encoding utf8

        # The failed start is surfaced as a dialog. Dismiss it, then restore a
        # clean disconnected baseline for the next independent attempt.
        Invoke-Adb shell input keyevent 4 | Out-Null
        Invoke-Adb shell am start -n $targetActivity | Out-Null
        $stopped = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 35
        if ($stopped.phase -ne "DISCONNECTED") {
            throw "cycle ${cycle}: rejected start did not settle (phase=$($stopped.phase))"
        }
        continue
    }
    if ($connected.phase -ne "CONNECTED") {
        throw "cycle ${cycle}: connect did not complete (phase=$($connected.phase))"
    }
    $connectedMs = [long](($connected.at - $startAt).TotalMilliseconds)
    $vpnBefore = Get-VpnState
    $before = Get-TunCounters -Interface $vpnBefore.interface

    if ($Scenario -eq "matrix") {
        Invoke-Adb shell am start -W -n $probeActivity --es run $run | Out-Null
    } else {
        Invoke-Adb shell am start -W -n $probeActivity --es run $run --es scenario $Scenario --ei repetitions $ProbeRepetitions --ei parallel 1 --ei bytes 65536 | Out-Null
    }
    $probeDeadline = (Get-Date).AddSeconds($ProbeDeadlineSeconds)
    $probeLines = @()
    do {
        Start-Sleep -Milliseconds 500
        $probeLines = @(Invoke-Adb logcat -d -v threadtime -s @probeLogTags | Select-String -Pattern $run)
        $complete = $probeLines | Where-Object {
            $_ -match $(if ($Scenario -eq "matrix") { 'target=matrix event=complete' } else { 'event=probe_complete' })
        }
    } while (-not $complete -and (Get-Date) -lt $probeDeadline)

    $probeTimedOut = -not $complete
    $vpnAfter = Get-VpnState
    $after = Get-TunCounters -Interface $vpnAfter.interface

    # The probe activity is a separate foreground app. Bring ZEON's existing
    # task forward (without restarting its process) before checking visible UI.
    Invoke-Adb shell am start -n $targetActivity | Out-Null
    Start-Sleep -Milliseconds 700
    $visibleXml = Get-UiXml
    $uiStillConnected = (Get-UiPhase -Xml $visibleXml) -eq "CONNECTED"

    $probeLines = @(Invoke-Adb logcat -d -v threadtime -s @probeLogTags | Select-String -Pattern $run)
    $successes = @($probeLines | Where-Object { $_ -match 'event=success' }).Count
    $failures = @($probeLines | Where-Object { $_ -match 'event=failure' }).Count
    $dataPlaneDead = if ($Scenario -eq "matrix") {
        # A single destination failure is not a false-connected state.  Zero
        # successes is a full blackhole; one of four is a severe partial
        # blackhole matching a user app that remains offline while a narrow
        # control/probe path can still be alive.
        $successes -le 1 -and ($probeTimedOut -or $failures -gt 0)
    } else {
        $probeTimedOut -or $successes -lt $expectedSuccesses -or $failures -gt 0
    }
    $acceptedFailure = $uiStillConnected -and $vpnAfter.active -and $dataPlaneDead
    if ($acceptedFailure) { $falseConnected++ }

    $item = [pscustomobject]@{
        cycle = $cycle
        run = $run
        connected_ms = $connectedMs
        startup_rejected = $false
        ui_connected = $uiStillConnected
        probe_successes = $successes
        probe_failures = $failures
        probe_timed_out = $probeTimedOut
        vpn_active = $vpnAfter.active
        vpn_validated = $vpnAfter.validated
        tun_interface = $after.interface
        tun_rx_delta = $after.rx - $before.rx
        tun_tx_delta = $after.tx - $before.tx
        false_connected = $acceptedFailure
    }
    $summary.Add($item)
    $item | ConvertTo-Json -Compress | Write-Output
    $summary | Export-Csv -LiteralPath (Join-Path $runDirectory "summary.csv") -NoTypeInformation -Encoding utf8
    (Invoke-Adb logcat -d -v threadtime |
        Select-String -Pattern 'data_plane_probe_completed|start_gate_completed|vpn_snapshot.*phase=CONNECTED|vpn_status.*status=Started|ZEON_MATRIX') |
        Set-Content -LiteralPath (Join-Path $runDirectory "$run-gate-and-matrix-log.txt") -Encoding utf8

    if ($acceptedFailure) {
        Save-FailureEvidence -Run $run -Xml $visibleXml -Directory $runDirectory
        Invoke-Adb shell log -t ZEON_REPRO "run=$run event=false_connected_captured" | Out-Null
        break
    }

    if ($probeTimedOut) {
        $drainDeadline = (Get-Date).AddSeconds(35)
        do {
            Start-Sleep -Milliseconds 500
            $probeLines = @(Invoke-Adb logcat -d -v threadtime -s @probeLogTags | Select-String -Pattern $run)
            $complete = $probeLines | Where-Object {
                $_ -match $(if ($Scenario -eq "matrix") { 'target=matrix event=complete' } else { 'event=probe_complete' })
            }
        } while (-not $complete -and (Get-Date) -lt $drainDeadline)
    }
}

$result = [pscustomobject]@{
    requested_cycles = $Cycles
    completed_cycles = $summary.Count
    startup_rejected = $startupRejected
    connected_cycles = @($summary | Where-Object { -not $_.startup_rejected }).Count
    false_connected = $falseConnected
    evidence_directory = $runDirectory
}
$result | ConvertTo-Json | Tee-Object -FilePath (Join-Path $runDirectory "result.json")
if ($falseConnected -gt 0) { exit 2 }
