[CmdletBinding()]
param([string]$LabRoot = 'C:\ZEON-LAB')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')

$lockPath = Join-Path $LabRoot 'state\runtime\runner.lock'
$lockStream = $null
try {
    $lockStream = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    exit 0
}

$activePath = Join-Path $LabRoot 'state\runtime\active-run.json'
$armingPath = $null
$fixturePlaintextPath = $null
$fixtureEncryptedPath = $null
$temporaryRunRoot = $null
$runDirectory = $null
$status = $null
$eventsPath = $null
$requestFile = $null
$process = $null
$processExitCode = $null
$timedOut = $false
$recoveryOk = $false

try {
    $queueDirectory = Join-Path $LabRoot 'state\runtime\queue'
    $requestFile = Get-ChildItem -LiteralPath $queueDirectory -Filter '*.request.json' -File |
        Sort-Object LastWriteTimeUtc |
        Select-Object -First 1
    if (-not $requestFile) { exit 0 }

    $request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
    $runId = [string]$request.run_id
    Assert-RuntimeSafeId -Value $runId -Label 'run_id'
    if ([string]$request.scenario -notin @('preflight', 'connect') -or [string]$request.mode -ne 'system-proxy') {
        throw 'Queued request is outside the enabled runtime scope.'
    }
    $runDirectory = Join-Path $LabRoot ("evidence\runs\{0}" -f $runId)
    $statusPath = Join-Path $runDirectory 'status.json'
    $eventsPath = Join-Path $runDirectory 'controller-events.jsonl'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Queued status is missing.' }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if ([string]$status.status -ne 'queued') { throw 'Queued status is not immutable queued state.' }

    $startedAt = (Get-Date).ToUniversalTime()
    $deadline = $startedAt.AddSeconds([int]$request.execution_timeout_seconds)
    $status.status = 'running'
    $status.started_at = $startedAt.ToString('o')
    $status.deadline = $deadline.ToString('o')
    Write-RuntimeAtomicJson -Value $status -Path $statusPath
    Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'running'

    $artifactDirectory = Join-Path $LabRoot ("artifacts\{0}\{1}" -f $request.version, [int]$request.build_number)
    $zipPath = Join-Path $artifactDirectory ([string]$request.artifact_file)
    if ((Get-RuntimeFileHash -Path $zipPath) -cne ([string]$request.artifact_sha256).ToLowerInvariant()) {
        throw 'Runtime ZIP changed after queue validation.'
    }

    $temporaryRunRoot = Join-Path $LabRoot ("temp\runtime\{0}" -f $runId)
    if (Test-Path -LiteralPath $temporaryRunRoot) { throw 'Runtime temp directory already exists.' }
    $applicationRoot = Join-Path $temporaryRunRoot 'app'
    New-Item -ItemType Directory -Path $applicationRoot -Force | Out-Null
    Set-RuntimeRestrictedAcl -Path $temporaryRunRoot
    Expand-Archive -LiteralPath $zipPath -DestinationPath $applicationRoot
    $executablePath = Join-Path $applicationRoot 'ZEON.exe'
    $corePath = Join-Path $applicationRoot 'hiddify-core.dll'
    if ((Get-RuntimeFileHash -Path $executablePath) -cne ([string]$request.executable_sha256).ToLowerInvariant()) { throw 'Extracted executable hash mismatch.' }
    if ((Get-RuntimeFileHash -Path $corePath) -cne ([string]$request.native_core_sha256).ToLowerInvariant()) { throw 'Extracted native core hash mismatch.' }

    $baselinePath = Join-Path $runDirectory 'before-network.json'
    $baseline = Get-RuntimeNetworkState -UserSid 'S-1-5-18'
    Write-RuntimeAtomicJson -Value $baseline -Path $baselinePath
    $heartbeatPath = Join-Path $runDirectory 'heartbeat.json'
    $active = [ordered]@{
        schema_version = 1
        run_id = $runId
        scenario = [string]$request.scenario
        mode = [string]$request.mode
        run_directory = $runDirectory
        application_root = $applicationRoot
        baseline_path = $baselinePath
        heartbeat_path = $heartbeatPath
        deadline = $deadline.ToString('o')
        test_process_ids = @()
        reboot_allowed = $false
    }
    Write-RuntimeAtomicJson -Value $active -Path $activePath
    $armingPath = Join-Path $LabRoot ("state\runtime\arming\{0}.json" -f $runId)
    $arming = [ordered]@{
        schema_version = 1
        run_id = $runId
        active_run_path = $activePath
        allow_apply = $true
        consumed = $false
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        expires_at = $deadline.AddMinutes(10).ToString('o')
        request_sha256 = [string]$request.request_sha256
        reboot_allowed = $false
    }
    Write-RuntimeAtomicJson -Value $arming -Path $armingPath

    if ([string]$request.scenario -eq 'connect') {
        $fixtureEncryptedPath = Join-Path $env:ProgramData ("ZEON-LAB-Secrets\{0}.dpapi" -f $request.fixture_id)
        $fixtureTempRoot = Join-Path $env:SystemRoot ("Temp\ZEON-LAB-runtime\{0}" -f $runId)
        New-Item -ItemType Directory -Path $fixtureTempRoot -Force | Out-Null
        Set-RuntimeRestrictedAcl -Path $fixtureTempRoot
        $fixturePlaintextPath = Join-Path $fixtureTempRoot 'profile.fixture'
        $protected = [IO.File]::ReadAllBytes($fixtureEncryptedPath)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try {
            [IO.File]::WriteAllBytes($fixturePlaintextPath, $plain)
            Set-RuntimeRestrictedAcl -Path $fixturePlaintextPath
            if ((Get-RuntimeFileHash -Path $fixturePlaintextPath) -cne ([string]$request.fixture_sha256).ToLowerInvariant()) {
                throw 'Decrypted fixture SHA-256 mismatch.'
            }
        } finally {
            [Array]::Clear($plain, 0, $plain.Length)
        }
    }

    $runtimeEvidence = Join-Path $runDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtimeEvidence -Force | Out-Null
    $arguments = @(
        '--scenario', [string]$request.scenario,
        '--mode', 'system-proxy',
        '--evidence-dir', $runtimeEvidence,
        '--run-id', $runId,
        '--connect-timeout-seconds', [string][int]$request.connect_timeout_seconds,
        '--bootstrap-timeout-seconds', [string][int]$request.bootstrap_timeout_seconds,
        '--cleanup-timeout-seconds', [string][int]$request.cleanup_timeout_seconds,
        '--scenario-timeout-seconds', [string][int]$request.scenario_timeout_seconds,
        '--traffic-url', [string]$request.traffic_url
    )
    if ($fixturePlaintextPath) { $arguments += @('--profile-file', $fixturePlaintextPath) }
    $quotedArguments = @($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' '
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executablePath
    $startInfo.WorkingDirectory = $applicationRoot
    $startInfo.Arguments = $quotedArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy')) {
        $startInfo.EnvironmentVariables.Remove($name)
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start runtime executable.' }
    $stdoutRead = $process.StandardOutput.ReadToEndAsync()
    $stderrRead = $process.StandardError.ReadToEndAsync()
    Start-Sleep -Milliseconds 750
    $process.Refresh()
    $status.pid = $process.Id
    $status.main_window_handle = [int64]$process.MainWindowHandle
    $status.ui_created = [int64]$process.MainWindowHandle -ne 0
    Write-RuntimeAtomicJson -Value $status -Path $statusPath
    Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'process_started' -Details @{ pid = $process.Id; main_window_handle = [int64]$process.MainWindowHandle }

    while (-not $process.HasExited) {
        $process.Refresh()
        if ([int64]$process.MainWindowHandle -ne 0) {
            $status.ui_created = $true
            $status.main_window_handle = [int64]$process.MainWindowHandle
        }
        $ownedIds = @(Get-RuntimeOwnedProcessIds -ApplicationRoot $applicationRoot)
        if ($ownedIds -notcontains $process.Id) { $ownedIds += $process.Id }
        $active.test_process_ids = @($ownedIds | Sort-Object -Unique)
        Write-RuntimeAtomicJson -Value $active -Path $activePath
        $heartbeat = [ordered]@{
            run_id = $runId
            utc = (Get-Date).ToUniversalTime().ToString('o')
            deadline = $deadline.ToString('o')
            pid = $process.Id
            owned_process_ids = $active.test_process_ids
        }
        Write-RuntimeAtomicJson -Value $heartbeat -Path $heartbeatPath
        if ((Get-Date).ToUniversalTime() -ge $deadline) {
            $timedOut = $true
            $ownedResult = Stop-RuntimeOwnedProcesses -ProcessIds @($active.test_process_ids | ForEach-Object { [int]$_ }) -ApplicationRoot $applicationRoot
            Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'deadline_exceeded' -Details @{ stopped_process_ids = @($ownedResult.stopped) }
            break
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
    }
    if (-not $process.HasExited) { $process.WaitForExit(10000) | Out-Null }
    if (-not $process.HasExited) { throw 'Runtime process did not terminate after its finite deadline.' }
    if ($process.HasExited) { $processExitCode = $process.ExitCode }
    $stdoutRead.Result | Set-Content -LiteralPath (Join-Path $runDirectory 'stdout.log') -Encoding utf8
    $stderrRead.Result | Set-Content -LiteralPath (Join-Path $runDirectory 'stderr.log') -Encoding utf8

    try {
        & (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId $runId -LabRoot $LabRoot | Out-Null
        $recoveryOk = $true
    } catch {
        $recoveryOk = $false
        Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'external_recovery_failed' -Details @{ failure_type = $_.Exception.GetType().Name }
    }
    $armingPath = $null

    $runtimeResultPath = Join-Path $runtimeEvidence 'result.json'
    $runtimeResult = $null
    if (Test-Path -LiteralPath $runtimeResultPath -PathType Leaf) {
        $runtimeResult = Get-Content -LiteralPath $runtimeResultPath -Raw | ConvertFrom-Json
    }
    $runtimeCleanup = $runtimeResult -and [bool]$runtimeResult.cleanup.verified
    $runtimePass = $runtimeResult -and [string]$runtimeResult.verdict -eq 'PASS'
    $listenerOwnerVerified = $null
    if ([string]$request.scenario -eq 'connect') {
        $connectedNetworkPath = Join-Path $runtimeEvidence 'connected-network.json'
        if (Test-Path -LiteralPath $connectedNetworkPath) {
            $connectedNetwork = Get-Content -LiteralPath $connectedNetworkPath -Raw | ConvertFrom-Json
            $netstat = [string]$connectedNetwork.tcp_endpoints.stdout
            $listenerMatch = [regex]::Match($netstat, '(?im)^\s*TCP\s+\S+:13434\s+\S+\s+LISTENING\s+(\d+)\s*$')
            $listenerOwnerVerified = $listenerMatch.Success -and [int]$listenerMatch.Groups[1].Value -eq [int]$status.pid
        } else {
            $listenerOwnerVerified = $false
        }
    }
    $status.listener_owner_verified = $listenerOwnerVerified
    $status.exit_code = $processExitCode
    $status.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    if ($timedOut) {
        $status.status = if ($recoveryOk) { 'recovered' } else { 'timed_out' }
        $status.previous_status = 'timed_out'
        $status.failure_reason = 'execution_deadline_exceeded'
    } elseif ($processExitCode -eq 0 -and $runtimePass -and $runtimeCleanup -and $recoveryOk -and -not [bool]$status.ui_created -and ($null -eq $listenerOwnerVerified -or $listenerOwnerVerified)) {
        $status.status = 'completed'
        $status.failure_reason = $null
    } else {
        $status.status = if ($recoveryOk) { 'recovered' } else { 'failed' }
        $status.previous_status = 'failed'
        $status.failure_reason = if (-not $runtimeResult) { 'runtime_result_missing' } elseif (-not $runtimeCleanup) { 'runtime_cleanup_unverified' } elseif (-not $recoveryOk) { 'external_recovery_failed' } elseif ([bool]$status.ui_created) { 'unexpected_window_created' } elseif ($listenerOwnerVerified -eq $false) { 'proxy_listener_owner_unverified' } else { 'runtime_failed' }
        $status.failure_detail = if ($runtimeResult) { [string]$runtimeResult.reason } else { $null }
    }

    Write-RuntimeAtomicJson -Value $status -Path $statusPath
    $secretScan = Protect-RuntimeEvidence -EvidenceDirectory $runDirectory -FixturePlaintextPath $fixturePlaintextPath
    Write-RuntimeAtomicJson -Value $secretScan -Path (Join-Path $runDirectory 'secret-scan.json')
    $status.secret_scan_clean = [bool]$secretScan.clean
    $status.safe_to_collect = [bool]$secretScan.clean
    Write-RuntimeAtomicJson -Value $status -Path $statusPath
    Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'terminal' -Details @{ status = [string]$status.status; exit_code = $processExitCode; recovery_ok = $recoveryOk; secret_scan_clean = [bool]$secretScan.clean }
} catch {
    $failure = $_.Exception.Message
    if ($runDirectory -and (Test-Path -LiteralPath $runDirectory)) {
        if ($activePath -and (Test-Path -LiteralPath $activePath) -and $armingPath -and (Test-Path -LiteralPath $armingPath)) {
            try {
                & (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId ([string]$status.run_id) -LabRoot $LabRoot | Out-Null
                $recoveryOk = $true
            } catch {
                $recoveryOk = $false
            }
            $armingPath = $null
        }
        if (-not $status) {
            $status = [pscustomobject]@{ schema_version = 1; run_id = $requestFile.BaseName; scenario = $null; mode = $null; status = 'failed'; queued_at = $null; started_at = $null; completed_at = $null; deadline = $null; pid = $null; exit_code = $null; main_window_handle = $null; ui_created = $false; previous_status = $null; failure_reason = $null; failure_detail = $null; failure_type = $null; listener_owner_verified = $null; secret_scan_clean = $false; safe_to_collect = $false }
        }
        $status.status = if ($recoveryOk) { 'recovered' } else { 'failed' }
        $status.previous_status = 'failed'
        $status.failure_reason = 'runner_exception'
        $status.failure_detail = $failure
        $status.failure_type = $_.Exception.GetType().Name
        $status.completed_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-RuntimeAtomicJson -Value $status -Path (Join-Path $runDirectory 'status.json')
        $secretScan = Protect-RuntimeEvidence -EvidenceDirectory $runDirectory -FixturePlaintextPath $fixturePlaintextPath
        Write-RuntimeAtomicJson -Value $secretScan -Path (Join-Path $runDirectory 'secret-scan.json')
        $status.secret_scan_clean = [bool]$secretScan.clean
        $status.safe_to_collect = [bool]$secretScan.clean
        Write-RuntimeAtomicJson -Value $status -Path (Join-Path $runDirectory 'status.json')
        if ($eventsPath) { Add-RuntimeEvent -EventsPath $eventsPath -RunId ([string]$status.run_id) -Event 'runner_failed' -Details @{ failure_type = $_.Exception.GetType().Name; recovered = $recoveryOk } }
    }
} finally {
    if ($fixturePlaintextPath) {
        $fixtureDirectory = Split-Path -Parent $fixturePlaintextPath
        Remove-Item -LiteralPath $fixturePlaintextPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Force -Recurse -ErrorAction SilentlyContinue }
    }
    if ($fixtureEncryptedPath) { Remove-Item -LiteralPath $fixtureEncryptedPath -Force -ErrorAction SilentlyContinue }
    if ($temporaryRunRoot -and (Test-Path -LiteralPath $temporaryRunRoot)) { Remove-Item -LiteralPath $temporaryRunRoot -Force -Recurse -ErrorAction SilentlyContinue }
    if ($armingPath -and (Test-Path -LiteralPath $armingPath)) { Remove-Item -LiteralPath $armingPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
    if ($requestFile -and (Test-Path -LiteralPath $requestFile.FullName)) {
        $archivePath = Join-Path $LabRoot ("state\runtime\archive\{0}" -f $requestFile.Name)
        Move-Item -LiteralPath $requestFile.FullName -Destination $archivePath -Force
    }
    if ($lockStream) { $lockStream.Dispose() }
}
exit 0
