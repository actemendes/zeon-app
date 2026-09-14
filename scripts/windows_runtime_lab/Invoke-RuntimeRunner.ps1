[CmdletBinding()]
param([string]$LabRoot = 'C:\ZEON-LAB')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')
Add-Type -AssemblyName System.Security

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
$rawBaselinePath = $null
$ownedStatePath = $null
$runtimeUserDataPath = $null

try {
    $queueDirectory = Join-Path $LabRoot 'state\runtime\queue'
    $requestFile = Get-ChildItem -LiteralPath $queueDirectory -Filter '*.request.json' -File |
        Sort-Object LastWriteTimeUtc |
        Select-Object -First 1
    if (-not $requestFile) { exit 0 }

    $request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
    if ([int]$request.schema_version -ne 2 -or [string]$request.controller_schema -cne 'zeon.remote-controller.v2' -or [string]$request.runtime_schema -cne 'zeon.windows-runtime.v1') {
        throw 'Queued request schema differs from the installed runner.'
    }
    $runId = [string]$request.run_id
    Assert-RuntimeSafeId -Value $runId -Label 'run_id'
    if ([string]$request.scenario -notin @('preflight', 'connect', 's02', 's06', 'manual-proxy', 'auto-proxy', 'p03-r17') -or [string]$request.mode -notin @('system-proxy', 'tun', 'local-proxy')) {
        throw 'Queued request is outside the enabled runtime scope.'
    }
    $deployment = Get-Content -LiteralPath (Join-Path $LabRoot 'state\runtime\deployment.json') -Raw | ConvertFrom-Json
    $expectedSid = [string]$deployment.task.sid
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $currentIdentity.User.Value
    if ($currentSid -cne $expectedSid) { throw 'Runtime runner identity differs from the installed test principal.' }
    $runDirectory = Join-Path $LabRoot ("evidence\runs\{0}" -f $runId)
    $statusPath = Join-Path $runDirectory 'status.json'
    $eventsPath = Join-Path $runDirectory 'controller-events.jsonl'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Queued status is missing.' }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if ([string]$status.status -ne 'queued') { throw 'Queued status is not immutable queued state.' }

    $startedAt = (Get-Date).ToUniversalTime()
    $deadline = $startedAt.AddSeconds([int]$request.execution_timeout_seconds)
    $status.status = 'running'
    $status.runtime_identity = $currentIdentity.Name
    $status.runtime_sid = $currentSid
    $status.started_at = $startedAt.ToString('o')
    $status.deadline = $deadline.ToString('o')
    Write-RuntimeAtomicJson -Value $status -Path $statusPath
    Add-RuntimeEvent -EventsPath $eventsPath -RunId $runId -Event 'running'

    $profilePath = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$currentSid" -ErrorAction Stop).ProfileImagePath)
    $runtimeUserDataPath = Assert-RuntimePathWithin -Path (Join-Path $profilePath 'AppData\Roaming\zeon') -Root $profilePath -Label 'runtime user data path'
    if (Test-Path -LiteralPath $runtimeUserDataPath) { Remove-Item -LiteralPath $runtimeUserDataPath -Force -Recurse }

    $artifactDirectory = Join-Path $LabRoot ("artifacts\{0}\{1}" -f $request.version, [int]$request.build_number)
    $zipPath = Join-Path $artifactDirectory ([string]$request.artifact_file)
    if ((Get-RuntimeFileHash -Path $zipPath) -cne ([string]$request.artifact_sha256).ToLowerInvariant()) {
        throw 'Runtime ZIP changed after queue validation.'
    }

    $temporaryRunRoot = Join-Path $LabRoot ("temp\runtime\{0}" -f $runId)
    if (Test-Path -LiteralPath $temporaryRunRoot) { throw 'Runtime temp directory already exists.' }
    $applicationRoot = Join-Path $temporaryRunRoot 'app'
    New-Item -ItemType Directory -Path $applicationRoot -Force | Out-Null
    Set-RuntimeRestrictedAcl -Path $temporaryRunRoot -AdditionalFullControlSids @($currentSid)
    Expand-Archive -LiteralPath $zipPath -DestinationPath $applicationRoot
    $executablePath = Join-Path $applicationRoot 'ZEON.exe'
    $corePath = Join-Path $applicationRoot 'hiddify-core.dll'
    if ((Get-RuntimeFileHash -Path $executablePath) -cne ([string]$request.executable_sha256).ToLowerInvariant()) { throw 'Extracted executable hash mismatch.' }
    if ((Get-RuntimeFileHash -Path $corePath) -cne ([string]$request.native_core_sha256).ToLowerInvariant()) { throw 'Extracted native core hash mismatch.' }

    $rawBaselinePath = Join-Path $LabRoot ("state\runtime\baselines\{0}.json" -f $runId)
    $baseline = Get-RuntimeNetworkState -UserSid $currentSid
    Write-RuntimeAtomicJson -Value $baseline -Path $rawBaselinePath
    $baselineHash = Get-RuntimeFileHash -Path $rawBaselinePath
    $baselineForEvidence = Get-Content -LiteralPath $rawBaselinePath -Raw | ConvertFrom-Json
    Write-RuntimeAtomicJson -Value (Get-RuntimeSanitizedNetworkState -State $baselineForEvidence) -Path (Join-Path $runDirectory 'before-network.json')
    $ownedStatePath = Join-Path $LabRoot ("state\runtime\baselines\{0}.owned.json" -f $runId)
    $heartbeatPath = Join-Path $runDirectory 'heartbeat.json'
    $active = [ordered]@{
        schema_version = 2
        run_id = $runId
        scenario = [string]$request.scenario
        mode = [string]$request.mode
        run_directory = $runDirectory
        application_root = $applicationRoot
        user_sid = $currentSid
        runtime_identity = $currentIdentity.Name
        baseline_path = $rawBaselinePath
        baseline_sha256 = $baselineHash
        owned_state_path = $ownedStatePath
        heartbeat_path = $heartbeatPath
        deadline = $deadline.ToString('o')
        test_process_ids = @()
        fixture_plaintext_path = $null
        fixture_encrypted_path = $null
        runtime_user_data_path = $runtimeUserDataPath
        recovery_actions = @('stop_lab_owned_processes', 'restore_owned_wininet', 'restore_owned_winhttp', 'restore_owned_routes', 'restore_owned_dns', 'start_sshd_if_stopped', 'remove_runtime_plaintext', 'remove_runtime_user_data')
        reboot_allowed = $false
    }
    Write-RuntimeAtomicJson -Value $active -Path $activePath
    $armingPath = Join-Path $LabRoot ("state\runtime\arming\{0}.json" -f $runId)
    $arming = [ordered]@{
        schema_version = 2
        run_id = $runId
        active_run_path = $activePath
        user_sid = $currentSid
        baseline_sha256 = $baselineHash
        heartbeat_path = $heartbeatPath
        deadline = $deadline.ToString('o')
        pid_allowlist = @()
        recovery_actions = @($active.recovery_actions)
        allow_apply = $true
        consumed = $false
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        expires_at = $deadline.AddMinutes(10).ToString('o')
        request_sha256 = [string]$request.request_sha256
        reboot_allowed = $false
    }
    Write-RuntimeAtomicJson -Value $arming -Path $armingPath

    if ([string]$request.scenario -ne 'preflight') {
        $fixtureEncryptedPath = Join-Path $env:ProgramData ("ZEON-LAB-Secrets\{0}.dpapi" -f $request.fixture_id)
        $fixtureTempRoot = Join-Path $env:SystemRoot ("Temp\ZEON-LAB-runtime\{0}" -f $runId)
        New-Item -ItemType Directory -Path $fixtureTempRoot -Force | Out-Null
        Set-RuntimeRestrictedAcl -Path $fixtureTempRoot -AdditionalFullControlSids @($currentSid)
        $fixturePlaintextPath = Join-Path $fixtureTempRoot 'profile.fixture'
        $protected = [IO.File]::ReadAllBytes($fixtureEncryptedPath)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try {
            [IO.File]::WriteAllBytes($fixturePlaintextPath, $plain)
            Set-RuntimeRestrictedAcl -Path $fixturePlaintextPath -AdditionalFullControlSids @($currentSid)
            if ((Get-RuntimeFileHash -Path $fixturePlaintextPath) -cne ([string]$request.fixture_sha256).ToLowerInvariant()) {
                throw 'Decrypted fixture SHA-256 mismatch.'
            }
        } finally {
            [Array]::Clear($plain, 0, $plain.Length)
        }
        $active.fixture_plaintext_path = $fixturePlaintextPath
        $active.fixture_encrypted_path = $fixtureEncryptedPath
        Write-RuntimeAtomicJson -Value $active -Path $activePath
    }

    $runtimeEvidence = Join-Path $runDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtimeEvidence -Force | Out-Null
    $arguments = @(
        '--scenario', [string]$request.scenario,
        '--mode', [string]$request.mode,
        '--evidence-dir', $runtimeEvidence,
        '--run-id', $runId,
        '--connect-timeout-seconds', [string][int]$request.connect_timeout_seconds,
        '--bootstrap-timeout-seconds', [string][int]$request.bootstrap_timeout_seconds,
        '--cleanup-timeout-seconds', [string][int]$request.cleanup_timeout_seconds,
        '--scenario-timeout-seconds', [string][int]$request.scenario_timeout_seconds,
        '--backend-health-url', [string]$request.backend_health_url,
        '--s02-cycles', [string][int]$request.s02_cycles,
        '--cancel-phase', [string]$request.cancel_phase
    )
    foreach ($trafficUrl in @($request.traffic_urls)) { $arguments += @('--traffic-url', [string]$trafficUrl) }
    if ([string]$request.manual_proxy_tag) { $arguments += @('--manual-proxy-tag', [string]$request.manual_proxy_tag) }
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

    $lastOwnedCapture = [datetime]::MinValue
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
        $arming.pid_allowlist = @($active.test_process_ids)
        Write-RuntimeAtomicJson -Value $arming -Path $armingPath
        $heartbeat = [ordered]@{
            schema_version = 2
            run_id = $runId
            utc = (Get-Date).ToUniversalTime().ToString('o')
            deadline = $deadline.ToString('o')
            pid = $process.Id
            owned_process_ids = $active.test_process_ids
            user_sid = $currentSid
            baseline_sha256 = $baselineHash
        }
        Write-RuntimeAtomicJson -Value $heartbeat -Path $heartbeatPath
        if (((Get-Date).ToUniversalTime() - $lastOwnedCapture).TotalSeconds -ge 5) {
            $ownedState = Get-RuntimeNetworkState -UserSid $currentSid
            Write-RuntimeAtomicJson -Value $ownedState -Path $ownedStatePath
            $lastOwnedCapture = (Get-Date).ToUniversalTime()
        }
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
    if ([string]$request.scenario -ne 'preflight') {
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
    $status.cleanup_verified = [bool]($runtimeCleanup -and $recoveryOk)
    if ($timedOut) {
        $status.status = if ($recoveryOk) { 'recovered' } else { 'timed_out' }
        $status.previous_status = 'timed_out'
        $status.verdict = if ([bool]$request.expected_timeout_drill -and $recoveryOk) { 'PASS' } else { 'FAIL' }
        $status.classification = if ([bool]$request.expected_timeout_drill) { 'harness-drill' } else { 'harness' }
        $status.failure_reason = if ([bool]$request.expected_timeout_drill -and $recoveryOk) { $null } else { 'execution_deadline_exceeded' }
        $status.cleanup_verified = $recoveryOk
    } elseif ($runtimeResult -and $runtimeCleanup -and $recoveryOk -and -not [bool]$status.ui_created -and ($null -eq $listenerOwnerVerified -or $listenerOwnerVerified)) {
        $status.status = 'completed'
        $status.verdict = [string]$runtimeResult.verdict
        $status.classification = switch ([string]$runtimeResult.verdict) {
            'PASS' { 'pass' }
            'FAIL' { 'product' }
            'HARNESS_ERROR' { 'harness' }
            'ENVIRONMENT_ERROR' { 'environment' }
            default { 'unknown' }
        }
        $status.failure_reason = if ([string]$runtimeResult.verdict -eq 'PASS') { $null } else { [string]$runtimeResult.reason }
        $status.failure_detail = if ([string]$runtimeResult.verdict -eq 'PASS') { $null } else { [string]$runtimeResult.reason }
    } else {
        $status.status = if ($recoveryOk) { 'recovered' } else { 'failed' }
        $status.previous_status = 'failed'
        $status.verdict = 'FAIL'
        $status.classification = 'harness'
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
            $status = [pscustomobject]@{ schema_version = 2; run_id = $requestFile.BaseName; scenario = $null; mode = $null; status = 'failed'; verdict = 'FAIL'; classification = 'harness'; queued_at = $null; started_at = $null; completed_at = $null; deadline = $null; pid = $null; exit_code = $null; main_window_handle = $null; ui_created = $false; previous_status = $null; failure_reason = $null; failure_detail = $null; failure_type = $null; listener_owner_verified = $null; secret_scan_clean = $false; safe_to_collect = $false; runtime_identity = $null; runtime_sid = $null; cleanup_verified = $false }
        }
        $status.status = if ($recoveryOk) { 'recovered' } else { 'failed' }
        $status.previous_status = 'failed'
        $status.verdict = 'FAIL'
        $status.classification = 'harness'
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
    if ($recoveryOk) {
        if ($armingPath -and (Test-Path -LiteralPath $armingPath)) { Remove-Item -LiteralPath $armingPath -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
        if ($rawBaselinePath) { Remove-Item -LiteralPath $rawBaselinePath -Force -ErrorAction SilentlyContinue }
        if ($ownedStatePath) { Remove-Item -LiteralPath $ownedStatePath -Force -ErrorAction SilentlyContinue }
    }
    if ($requestFile -and (Test-Path -LiteralPath $requestFile.FullName)) {
        $archivePath = Join-Path $LabRoot ("state\runtime\archive\{0}" -f $requestFile.Name)
        Move-Item -LiteralPath $requestFile.FullName -Destination $archivePath -Force
    }
    if ($lockStream) { $lockStream.Dispose() }
}
exit 0
