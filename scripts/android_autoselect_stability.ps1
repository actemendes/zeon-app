[CmdletBinding()]
param(
    [ValidateRange(60, 180)]
    [int]$DurationSeconds = 180,

    [string]$DeviceId = "18bfc103",

    [string]$EvidenceRoot = "artifacts/android_false_connected/autoselect_stability"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$targetPackage = "com.zeon.hiddify.validation"
$probeService = "com.zeon.hiddify.validation.test/test.com.zeon.zeon.bg.VerificationTrafficService"
$protoRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) "android/app/src/main/protos"))
$grpc = (Get-Command grpcurl.exe).Source
$adbExecutable = (Get-Command adb.exe).Source
$resolvedRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
$directory = Join-Path $resolvedRoot (Get-Date -Format "yyyyMMdd_HHmmss")
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$run = "auto_stability_" + (Get-Date -Format "yyyyMMdd_HHmmss")

function Invoke-Adb {
    & adb -s $DeviceId @args
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $($args -join ' ')" }
}

function Get-CurrentOutboundId {
    $arguments = @(
        '-plaintext',
        '-max-time', '1',
        '-import-path', $protoRoot,
        '-proto', 'v2/hcore/hcore_service.proto',
        '-d', '{}',
        'localhost:17178',
        'hcore.Core/GetSystemInfo'
    )
    $raw = (& $grpc @arguments 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return "" }
    try {
        $system = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return ""
    }
    $outbound = [string]$system.currentOutbound
    if (-not $outbound) { return "" }
    $sha = [Security.Cryptography.SHA256]::Create()
    return [BitConverter]::ToString(
        $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($outbound))
    ).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}

Invoke-Adb forward tcp:17178 tcp:17178 | Out-Null
$initial = Get-CurrentOutboundId
if (-not $initial) { throw "core current_outbound is unavailable; Autoselect must already be connected" }

Invoke-Adb logcat -c | Out-Null
$remoteVideo = "/sdcard/$run.mp4"
$record = Start-Job -ScriptBlock {
    param($Executable, $Serial, $Seconds, $Remote)
    & $Executable -s $Serial shell screenrecord --time-limit $Seconds --bit-rate 4000000 $Remote
} -ArgumentList $adbExecutable, $DeviceId, $DurationSeconds, $remoteVideo

$samples = [Collections.Generic.List[object]]::new()
$changes = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastId = ""
$nextTrafficAt = 0
$trafficRuns = [Collections.Generic.List[string]]::new()

while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $elapsed = $clock.ElapsedMilliseconds
    $id = Get-CurrentOutboundId
    if ($id) {
        $samples.Add([pscustomobject]@{ elapsed_ms = $elapsed; outbound_id = $id })
        if ($id -ne $lastId) {
            $changes.Add([pscustomobject]@{
                elapsed_ms = $elapsed
                old_id = $lastId
                new_id = $id
            })
            $lastId = $id
        }
    }
    if ($clock.Elapsed.TotalSeconds -ge $nextTrafficAt) {
        $trafficRun = "${run}_traffic_$nextTrafficAt"
        Invoke-Adb shell am start-foreground-service -n $probeService --es run $trafficRun | Out-Null
        $trafficRuns.Add($trafficRun)
        $nextTrafficAt += 30
    }
    Start-Sleep -Milliseconds 350
}

Start-Sleep -Seconds 6
Wait-Job -Job $record -Timeout 10 | Out-Null
Receive-Job -Job $record -ErrorAction SilentlyContinue | Out-Null
Invoke-Adb pull $remoteVideo (Join-Path $directory "$run-screen.mp4") | Out-Null

$safeLog = @(
    Invoke-Adb logcat -d -v threadtime |
        Select-String -Pattern 'A/VpnSession|ZEON_VERIFY|event=selector_switch|event=stale_callback_ignored|ConnectionNotifier'
)
$safeLog | Set-Content -LiteralPath (Join-Path $directory "$run-timeline.txt") -Encoding utf8
$samples | Export-Csv -LiteralPath (Join-Path $directory "$run-outbound-samples.csv") -NoTypeInformation -Encoding utf8
$changes | Export-Csv -LiteralPath (Join-Path $directory "$run-outbound-changes.csv") -NoTypeInformation -Encoding utf8

$invalidations = @($safeLog | Where-Object { $_ -match 'event=data_plane_invalidated' }).Count
$outboundInvalidations = @($safeLog | Where-Object {
    $_ -match 'event=data_plane_invalidated' -and $_ -match 'source=selected_outbound_changed'
}).Count
$revalidations = @($safeLog | Where-Object { $_ -match 'event=data_plane_revalidation_completed' }).Count
$realPasses = @($safeLog | Where-Object {
    $_ -match 'target=(cloudflare_speed|apple_captive) event=real_http_pass'
}).Count
$realFailures = @($safeLog | Where-Object {
    $_ -match 'target=(cloudflare_speed|apple_captive) event=real_http_fail'
}).Count

$result = [ordered]@{
    duration_seconds = $DurationSeconds
    sample_count = $samples.Count
    unique_outbound_ids = @($samples.outbound_id | Sort-Object -Unique).Count
    outbound_changes = [Math]::Max(0, $changes.Count - 1)
    data_plane_invalidations = $invalidations
    outbound_invalidations = $outboundInvalidations
    revalidations = $revalidations
    traffic_runs = $trafficRuns.Count
    real_https_passes = $realPasses
    real_https_failures = $realFailures
    evidence_directory = $directory
}
$result | ConvertTo-Json | Tee-Object -FilePath (Join-Path $directory "result.json")
