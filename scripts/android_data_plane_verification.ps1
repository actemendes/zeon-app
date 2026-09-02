[CmdletBinding()]
param(
    [ValidateRange(1, 30)]
    [int]$Cycles = 10,

    [string]$DeviceId = "18bfc103",

    [string]$EvidenceRoot = "artifacts/android_false_connected/manual_known_good"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$targetPackage = "com.zeon.hiddify.validation"
$probePackage = "com.zeon.hiddify.validation.test"
$targetActivity = "$targetPackage/com.zeon.zeon.MainActivity"
$probeService = "$probePackage/test.com.zeon.zeon.bg.VerificationTrafficService"
$adbPrefix = @("-s", $DeviceId)

function Invoke-Adb {
    & adb @adbPrefix @args
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed: $($args -join ' ')"
    }
}

function Get-UiState {
    Invoke-Adb shell uiautomator dump /sdcard/zeon_verification_ui.xml 2>$null | Out-Null
    [xml]$document = (Invoke-Adb shell cat /sdcard/zeon_verification_ui.xml) -join "`n"
    $connect = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J3QsNC20LzQuNGC0LUg0LTQu9GPINC/0L7QtNC60LvRjtGH0LXQvdC40Y8=")
    )
    $disconnect = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String("0J3QsNC20LzQuNGC0LUg0LTQu9GPINC+0YLQutC70Y7Rh9C10L3QuNGP")
    )
    $connectNode = @($document.SelectNodes("//node") | Where-Object { $_.'content-desc' -eq $connect }) |
        Select-Object -First 1
    $disconnectNode = @($document.SelectNodes("//node") | Where-Object { $_.'content-desc' -eq $disconnect }) |
        Select-Object -First 1
    if ($disconnectNode) {
        return @{ phase = "CONNECTED"; bounds = [string]$disconnectNode.bounds }
    }
    if ($connectNode) {
        return @{ phase = "DISCONNECTED"; bounds = [string]$connectNode.bounds }
    }
    return @{ phase = "OTHER"; bounds = "" }
}

function Invoke-BoundsTap {
    param([Parameter(Mandatory = $true)][string]$Bounds)
    $values = @([regex]::Matches($Bounds, '\d+') | ForEach-Object { [int]$_.Value })
    if ($values.Count -ne 4) { throw "invalid accessibility bounds" }
    $x = [int](($values[0] + $values[2]) / 2)
    $y = [int](($values[1] + $values[3]) / 2)
    Invoke-Adb shell input tap $x $y | Out-Null
}

function Wait-UiPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 400
        $state = Get-UiState
        if ($state.phase -eq $Expected) { return $state }
    } while ((Get-Date) -lt $deadline)
    return $state
}

function Get-VpnState {
    $connectivity = (Invoke-Adb shell dumpsys connectivity) -join "`n"
    $marker = "ni{VPN CONNECTED extra: VPN:$targetPackage"
    $index = $connectivity.IndexOf($marker, [StringComparison]::Ordinal)
    if ($index -lt 0) {
        return @{ active = $false; validated = $false; interface = "" }
    }
    $length = [Math]::Min(6000, $connectivity.Length - $index)
    $block = $connectivity.Substring($index, $length)
    $interface = ""
    if ($block -match 'InterfaceName: (tun\d+)') { $interface = $Matches[1] }
    return @{
        active = $true
        validated = $block.Contains("IS_VALIDATED")
        interface = $interface
    }
}

function Get-TunCounters {
    param([string]$Interface = "")
    $pattern = if ($Interface) { '^\s*' + [regex]::Escape($Interface) + ':' } else { '^\s*tun\d+:' }
    $line = Invoke-Adb shell cat /proc/net/dev | Select-String -Pattern $pattern | Select-Object -First 1
    if (-not $line -or $line.Line.Trim() -notmatch '^(tun\d+):\s+(\d+)\s+(?:\d+\s+){7}(\d+)') {
        return @{ interface = ""; rx = 0L; tx = 0L }
    }
    return @{ interface = $Matches[1]; rx = [long]$Matches[2]; tx = [long]$Matches[3] }
}

function Get-SafeLog {
    return @(
        Invoke-Adb logcat -d -v threadtime |
            Select-String -Pattern 'A/VpnSession|ConnectionNotifier|ZEON_VERIFY|selector_switch|stale_callback_ignored'
    )
}

function Stop-ScreenRecord {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$Remote,
        [Parameter(Mandatory = $true)][string]$Local
    )
    $rawScreenPid = & adb @adbPrefix shell pidof screenrecord 2>$null | Select-Object -First 1
    $screenPid = if ($null -eq $rawScreenPid) { "" } else { $rawScreenPid.ToString().Trim() }
    if ($screenPid -match '^\d+$') {
        Invoke-Adb shell kill -2 $screenPid | Out-Null
    }
    Wait-Job -Job $Job -Timeout 8 | Out-Null
    Receive-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
    Invoke-Adb pull $Remote $Local | Out-Null
}

$resolvedRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
$runDirectory = Join-Path $resolvedRoot (Get-Date -Format "yyyyMMdd_HHmmss")
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
$summary = [Collections.Generic.List[object]]::new()

Invoke-Adb shell cmd window user-rotation lock 0 | Out-Null
Invoke-Adb shell am start -n $targetActivity | Out-Null
$baseline = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 30
if ($baseline.phase -ne "DISCONNECTED") {
    throw "manual campaign requires a disconnected Home baseline"
}

for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $run = "manual_{0:D2}_{1}" -f $cycle, (Get-Date -Format "yyyyMMdd_HHmmss")
    Invoke-Adb logcat -c | Out-Null
    Invoke-Adb shell log -t ZEON_REPRO "run=$run event=manual_cycle_start" | Out-Null

    $remoteVideo = "/sdcard/$run.mp4"
    $localVideo = Join-Path $runDirectory "$run-screen.mp4"
    $adbExecutable = (Get-Command adb.exe).Source
    $record = Start-Job -ScriptBlock {
        param($Executable, $Serial, $RemoteVideo)
        & $Executable -s $Serial shell screenrecord --time-limit 45 --bit-rate 4000000 $RemoteVideo
    } -ArgumentList $adbExecutable, $DeviceId, $remoteVideo
    Start-Sleep -Milliseconds 500

    $state = Get-UiState
    if ($state.phase -ne "DISCONNECTED") { throw "cycle ${cycle}: not disconnected" }
    $probeStartAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-Adb shell am start-foreground-service -n $probeService --es run $run | Out-Null
    $probeStarted = $true
    Start-Sleep -Milliseconds 150
    Invoke-BoundsTap -Bounds $state.bounds

    $verificationSeen = $false
    $tunCaptured = $false
    $tunBefore = @{ interface = ""; rx = 0L; tx = 0L }
    $tunLast = $tunBefore
    $vpnValidatedSeen = $false
    $watchDeadline = (Get-Date).AddSeconds(18)
    do {
        Start-Sleep -Milliseconds 120
        $log = (Invoke-Adb logcat -d -v brief) -join "`n"
        if ($log -match 'phase=VERIFYING') {
            $verificationSeen = $true
        }
        $vpnObserved = Get-VpnState
        if ($vpnObserved.active) {
            $vpnValidatedSeen = $vpnValidatedSeen -or $vpnObserved.validated
            $sample = Get-TunCounters -Interface $vpnObserved.interface
            if (-not $tunCaptured -and $sample.interface) {
                $tunBefore = $sample
                $tunCaptured = $true
            }
            if ($sample.interface) { $tunLast = $sample }
        }
        $nativeComplete = $log -match 'event=data_plane_probe_completed'
        $nativeTerminal = $log -match 'event=start_gate_(completed|rejected)'
    } while (-not ($nativeComplete -and $nativeTerminal) -and (Get-Date) -lt $watchDeadline)

    $trafficDeadline = (Get-Date).AddSeconds(38)
    do {
        Start-Sleep -Milliseconds 300
        $vpnObserved = Get-VpnState
        if ($vpnObserved.active) {
            $vpnValidatedSeen = $vpnValidatedSeen -or $vpnObserved.validated
            $sample = Get-TunCounters -Interface $vpnObserved.interface
            if (-not $tunCaptured -and $sample.interface) {
                $tunBefore = $sample
                $tunCaptured = $true
            }
            if ($sample.interface) { $tunLast = $sample }
        }
        $safeLog = Get-SafeLog
        $matrixComplete = @($safeLog | Where-Object { $_ -match "run=$run target=matrix event=complete" }).Count -gt 0
    } while ($probeStarted -and -not $matrixComplete -and (Get-Date) -lt $trafficDeadline)

    $safeLog = Get-SafeLog
    $nativeProbePass = @($safeLog | Where-Object {
        $_ -match 'event=data_plane_probe_completed' -and $_ -match 'ready=true'
    }).Count -gt 0
    $nativeProbeFail = @($safeLog | Where-Object {
        $_ -match 'event=data_plane_probe_completed' -and $_ -match 'ready=false'
    }).Count -gt 0
    $earlyRealPasses = @($safeLog | Where-Object {
        $_ -match "run=$run target=(cloudflare_speed|apple_captive) event=real_http_pass"
    }).Count
    $earlyRealFailures = @($safeLog | Where-Object {
        $_ -match "run=$run target=(cloudflare_speed|apple_captive) event=real_http_fail"
    }).Count
    $postRealPasses = 0
    $postRealFailures = 0
    if ($nativeProbePass) {
        $postRun = "${run}_post"
        Invoke-Adb shell am start-foreground-service -n $probeService --es run $postRun | Out-Null
        $postDeadline = (Get-Date).AddSeconds(25)
        do {
            Start-Sleep -Milliseconds 300
            $vpnObserved = Get-VpnState
            if ($vpnObserved.active) {
                $vpnValidatedSeen = $vpnValidatedSeen -or $vpnObserved.validated
                $sample = Get-TunCounters -Interface $vpnObserved.interface
                if ($sample.interface) { $tunLast = $sample }
            }
            $safeLog = Get-SafeLog
            $postComplete = @($safeLog | Where-Object {
                $_ -match "run=$postRun target=matrix event=complete"
            }).Count -gt 0
        } while (-not $postComplete -and (Get-Date) -lt $postDeadline)
        $postRealPasses = @($safeLog | Where-Object {
            $_ -match "run=$postRun target=(cloudflare_speed|apple_captive) event=real_http_pass"
        }).Count
        $postRealFailures = @($safeLog | Where-Object {
            $_ -match "run=$postRun target=(cloudflare_speed|apple_captive) event=real_http_fail"
        }).Count
    }

    $vpnAfter = Get-VpnState
    $safeLog = Get-SafeLog
    $safeLog | Set-Content -LiteralPath (Join-Path $runDirectory "$run-timeline.txt") -Encoding utf8
    $realPasses = if ($nativeProbePass) { $postRealPasses } else { $earlyRealPasses }
    $realFailures = if ($nativeProbePass) { $postRealFailures } else { $earlyRealFailures }
    $realTrafficPass = $realPasses -ge 1
    $classification = if ($nativeProbePass -and $realTrafficPass) {
        "A"
    } elseif ($nativeProbeFail -and -not $realTrafficPass) {
        "B"
    } elseif ($nativeProbeFail -and $realTrafficPass) {
        "C"
    } elseif ($nativeProbePass -and -not $realTrafficPass) {
        "D"
    } else {
        "INCOMPLETE"
    }

    $phaseSequence = @(
        $safeLog |
            Where-Object { $_ -match 'A/VpnSession.*event=vpn_snapshot.*phase=' } |
            ForEach-Object {
                if ($_ -match 'phase=([A-Z_]+)') { $Matches[1] }
            }
    )
    $connectedToVerifying = 0
    for ($index = 1; $index -lt $phaseSequence.Count; $index++) {
        if ($phaseSequence[$index - 1] -eq "CONNECTED" -and $phaseSequence[$index] -eq "VERIFYING") {
            $connectedToVerifying++
        }
    }
    $outboundInvalidations = @($safeLog | Where-Object {
        $_ -match 'event=data_plane_invalidated' -and $_ -match 'source=selected_outbound_changed'
    }).Count

    $visible = Get-UiState
    $item = [pscustomobject]@{
        cycle = $cycle
        run = $run
        verification_seen = $verificationSeen
        probe_process_started = $probeStarted
        probe_start_unix_ms = $probeStartAt
        native_probe_pass = $nativeProbePass
        native_probe_fail = $nativeProbeFail
        verifying_real_http_passes = $earlyRealPasses
        verifying_real_http_failures = $earlyRealFailures
        connected_real_http_passes = $postRealPasses
        connected_real_http_failures = $postRealFailures
        real_http_passes = $realPasses
        real_http_failures = $realFailures
        real_traffic_pass = $realTrafficPass
        classification = $classification
        vpn_active = $vpnAfter.active
        vpn_validated = $vpnAfter.validated
        vpn_validated_seen = $vpnValidatedSeen
        tun_interface = $tunLast.interface
        tun_rx_delta = [Math]::Max(0L, $tunLast.rx - $tunBefore.rx)
        tun_tx_delta = [Math]::Max(0L, $tunLast.tx - $tunBefore.tx)
        final_ui = $visible.phase
        connected_to_verifying = $connectedToVerifying
        outbound_invalidations = $outboundInvalidations
    }
    $summary.Add($item)
    $summary | Export-Csv -LiteralPath (Join-Path $runDirectory "summary.csv") -NoTypeInformation -Encoding utf8
    $item | ConvertTo-Json -Compress | Write-Output

    Start-Sleep -Seconds 2
    Stop-ScreenRecord -Job $record -Remote $remoteVideo -Local $localVideo

    if ($visible.phase -eq "CONNECTED") {
        Invoke-BoundsTap -Bounds $visible.bounds
        $stopped = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 30
        if ($stopped.phase -ne "DISCONNECTED") { throw "cycle ${cycle}: disconnect failed" }
    } else {
        Invoke-Adb shell input keyevent 4 | Out-Null
        Invoke-Adb shell am start -n $targetActivity | Out-Null
        $stopped = Wait-UiPhase -Expected "DISCONNECTED" -TimeoutSeconds 30
        if ($stopped.phase -ne "DISCONNECTED") { throw "cycle ${cycle}: rejected start did not settle" }
    }
}

$matrix = [ordered]@{
    requested = $Cycles
    completed = $summary.Count
    A = @($summary | Where-Object classification -eq "A").Count
    B = @($summary | Where-Object classification -eq "B").Count
    C = @($summary | Where-Object classification -eq "C").Count
    D = @($summary | Where-Object classification -eq "D").Count
    incomplete = @($summary | Where-Object classification -eq "INCOMPLETE").Count
    connected_to_verifying = ($summary | Measure-Object connected_to_verifying -Sum).Sum
    outbound_invalidations = ($summary | Measure-Object outbound_invalidations -Sum).Sum
    evidence_directory = $runDirectory
}
$matrix | ConvertTo-Json | Tee-Object -FilePath (Join-Path $runDirectory "result.json")
