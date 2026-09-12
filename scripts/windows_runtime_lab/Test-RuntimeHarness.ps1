[CmdletBinding()]
param(
    [string]$Version,
    [int]$BuildNumber,
    [switch]$ApplyNoOpRecovery,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')

$checks = New-Object Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
}

function Get-RuntimeUserRights([string]$Sid) {
    $path = Join-Path $env:TEMP ("zeon-runtime-rights-check-{0}.inf" -f [guid]::NewGuid().ToString('N'))
    try {
        & secedit.exe /export /cfg $path /areas USER_RIGHTS /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect runtime user rights.' }
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::Unicode)
        $account = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value
        $shortAccount = $account.Split('\')[-1]
        return @('SeBatchLogonRight', 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight') | ForEach-Object {
            $right = $_
            $line = @($text -split "`r?`n" | Where-Object { $_ -match ("^{0}\s*=" -f [regex]::Escape($right)) } | Select-Object -First 1)
            $tokens = if ($line) { @(($line[0].Split('=', 2)[1]).Split(',') | ForEach-Object { $_.Trim() }) } else { @() }
            [ordered]@{ name = $right; present = $tokens -contains "*$Sid" -or $tokens -contains $account -or $tokens -contains $shortAccount }
        }
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

$deploymentPath = Join-Path $LabRoot 'state\runtime\deployment.json'
$deployment = if (Test-Path -LiteralPath $deploymentPath) { Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json } else { $null }
Add-Check 'deployment_manifest' ($null -ne $deployment) $deploymentPath
$task = Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation' -ErrorAction SilentlyContinue
$watchdogTask = Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Watchdog' -ErrorAction SilentlyContinue
Add-Check 'runtime_task_present' ($null -ne $task) 'ZEON-LAB Runtime Validation'
$testUserSid = if ($deployment) { [string]$deployment.task.sid } else { '' }
$testUser = if ($testUserSid) { Get-LocalUser | Where-Object { $_.SID.Value -eq $testUserSid } } else { $null }
$runtimeRights = if ($testUserSid) { @(Get-RuntimeUserRights -Sid $testUserSid) } else { @() }
Add-Check 'runtime_test_principal' ($testUser -and $testUser.Enabled -and $task.Principal.UserId -in @('ZEONRuntime', "$env:COMPUTERNAME\ZEONRuntime") -and $task.Principal.LogonType -eq 'Password' -and $task.Principal.RunLevel -eq 'Highest') ("principal={0}; sid={1}" -f $task.Principal.UserId, $testUserSid)
Add-Check 'runtime_interactive_logon_denied' ($runtimeRights.Count -eq 3 -and @($runtimeRights | Where-Object { -not $_.present }).Count -eq 0) 'batch allowed; local and remote interactive logon denied'
Add-Check 'runtime_task_action' ($task -and [string]$task.Actions.Execute -match 'powershell' -and [string]$task.Actions.Arguments -eq '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1') 'fixed script action without request or secret arguments'
Add-Check 'watchdog_task_present' ($null -ne $watchdogTask) 'ZEON-LAB Runtime Watchdog'
Add-Check 'watchdog_task_system' ($watchdogTask -and $watchdogTask.Principal.UserId -eq 'SYSTEM' -and $watchdogTask.Principal.RunLevel -eq 'Highest') 'SYSTEM, highest'
Add-Check 'watchdog_default_dry_run' ($watchdogTask -and [string]$watchdogTask.Actions.Arguments -notmatch '(?i)-apply') 'apply requires one-time manifest'
Add-Check 'automatic_reboot_forbidden' ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -Raw) -notmatch '(?i)shutdown\.exe|Restart-Computer') 'recovery contains no reboot operation'

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'deployment-manifest.json') -Raw | ConvertFrom-Json
$hashesOk = $true
foreach ($entry in $manifest.files) {
    $path = Join-Path $PSScriptRoot ([string]$entry.name)
    if (-not (Test-Path -LiteralPath $path) -or (Get-RuntimeFileHash -Path $path) -cne ([string]$entry.sha256).ToLowerInvariant()) { $hashesOk = $false }
}
Add-Check 'installed_script_hashes' $hashesOk ("files={0}" -f @($manifest.files).Count)

$rootAcl = Get-Acl -LiteralPath $LabRoot
$unexpected = @($rootAcl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Where-Object { $_ -notin @('S-1-5-18','S-1-5-32-544') } | Sort-Object -Unique)
Add-Check 'lab_acl_restricted' ($rootAcl.AreAccessRulesProtected -and $unexpected.Count -eq 0) ("protected={0}; unexpected={1}" -f $rootAcl.AreAccessRulesProtected, $unexpected.Count)
$activePresent = Test-Path -LiteralPath (Join-Path $LabRoot 'state\runtime\active-run.json')
Add-Check 'no_active_runtime_run' (-not $activePresent) ("active={0}" -f $activePresent)
$zeonProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -Match '^(ZEON|ZEONCli)$')
Add-Check 'no_zeon_process' ($zeonProcesses.Count -eq 0) ("count={0}" -f $zeonProcesses.Count)

$artifact = $null
if ($Version -and $BuildNumber -gt 0) {
    $artifactDirectory = Join-Path $LabRoot ("artifacts\{0}\{1}" -f $Version, $BuildNumber)
    $artifactManifestPath = Join-Path $artifactDirectory 'artifact-manifest.json'
    if (Test-Path -LiteralPath $artifactManifestPath) { $artifact = Get-Content -LiteralPath $artifactManifestPath -Raw | ConvertFrom-Json }
    Add-Check 'artifact_published' ($null -ne $artifact) $artifactDirectory
}

$noOp = [ordered]@{ requested = [bool]$ApplyNoOpRecovery; passed = $false; result = $null }
if ($ApplyNoOpRecovery) {
    $selfTestId = 'RECOVERY-NOOP-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $runDirectory = Join-Path $LabRoot ("evidence\runs\{0}" -f $selfTestId)
    $applicationRoot = Join-Path $LabRoot ("temp\runtime\{0}\app" -f $selfTestId)
    $activePath = Join-Path $LabRoot 'state\runtime\active-run.json'
    $armingPath = Join-Path $LabRoot ("state\runtime\arming\{0}.json" -f $selfTestId)
    $baselinePath = Join-Path $LabRoot ("state\runtime\baselines\{0}.json" -f $selfTestId)
    $ownedPath = Join-Path $LabRoot ("state\runtime\baselines\{0}.owned.json" -f $selfTestId)
    $heartbeatPath = Join-Path $runDirectory 'heartbeat.json'
    New-Item -ItemType Directory -Path $applicationRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    try {
        $baseline = Get-RuntimeNetworkState -UserSid $testUserSid
        Write-RuntimeAtomicJson -Value $baseline -Path $baselinePath
        Copy-Item -LiteralPath $baselinePath -Destination $ownedPath
        $baselineHash = Get-RuntimeFileHash -Path $baselinePath
        $recoveryActions = @('stop_lab_owned_processes', 'restore_owned_wininet', 'restore_owned_winhttp', 'restore_owned_routes', 'restore_owned_dns', 'start_sshd_if_stopped', 'remove_runtime_plaintext')
        $active = [ordered]@{
            schema_version = 2
            run_id = $selfTestId
            run_directory = $runDirectory
            application_root = $applicationRoot
            user_sid = $testUserSid
            runtime_identity = [string]$deployment.task.principal
            baseline_path = $baselinePath
            baseline_sha256 = $baselineHash
            owned_state_path = $ownedPath
            heartbeat_path = $heartbeatPath
            deadline = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
            test_process_ids = @()
            fixture_plaintext_path = $null
            fixture_encrypted_path = $null
            recovery_actions = $recoveryActions
            reboot_allowed = $false
        }
        $arming = [ordered]@{
            schema_version = 2
            run_id = $selfTestId
            active_run_path = $activePath
            user_sid = $testUserSid
            baseline_sha256 = $baselineHash
            heartbeat_path = $heartbeatPath
            deadline = $active.deadline
            pid_allowlist = @()
            recovery_actions = $recoveryActions
            allow_apply = $true
            consumed = $false
            expires_at = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
        }
        Write-RuntimeAtomicJson -Value $active -Path $activePath
        Write-RuntimeAtomicJson -Value $arming -Path $armingPath
        & (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId $selfTestId -LabRoot $LabRoot | Out-Null
        $recoveryResult = Get-Content -LiteralPath (Join-Path $runDirectory 'recovery-result.json') -Raw | ConvertFrom-Json
        $noOp.passed = [bool]$recoveryResult.success -and -not [bool]$recoveryResult.sshd_restarted -and -not [bool]$recoveryResult.reboot_scheduled
        $noOp.result = $recoveryResult
    } finally {
        Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $armingPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $baselinePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ownedPath -Force -ErrorAction SilentlyContinue
        $runtimeTestRoot = Split-Path -Parent $applicationRoot
        if (Test-Path -LiteralPath $runtimeTestRoot) { Remove-Item -LiteralPath $runtimeTestRoot -Force -Recurse }
    }
    Add-Check 'recovery_apply_noop' ([bool]$noOp.passed) 'run-scoped one-time arming; no process, network, sshd or reboot mutation'
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$report = [ordered]@{
    schema_version = 2
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    result = if (@($checks | Where-Object { -not $_.passed }).Count -eq 0) { 'READY_FOR_ACCEPTANCE' } else { 'BLOCKED_BY_REMOTE_HARNESS' }
    hostname = $env:COMPUTERNAME
    operating_system = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR; architecture = $os.OSArchitecture }
    resources = [ordered]@{ logical_processors = $cs.NumberOfLogicalProcessors; total_ram_bytes = [uint64]$cs.TotalPhysicalMemory; free_ram_bytes = [uint64]$os.FreePhysicalMemory * 1KB; disk_free_bytes = [uint64]$disk.FreeSpace }
    controller_sha = [string]$manifest.controller_sha
    scripts = $manifest.files
    task = if ($task) { [ordered]@{ name = $task.TaskName; path = $task.TaskPath; principal = $task.Principal.UserId; sid = $testUserSid; logon_type = $task.Principal.LogonType.ToString(); run_level = $task.Principal.RunLevel.ToString(); execute = $task.Actions.Execute; arguments = $task.Actions.Arguments } } else { $null }
    watchdog = [ordered]@{ task = 'ZEON-LAB Runtime Watchdog'; default_mode = 'dry_run'; apply_gate = 'one-time run-scoped arming manifest'; no_op_apply = $noOp }
    artifact = $artifact
    checks = $checks
    limitations = @(
        'Actual OS is Windows Server 2022, not Windows 10; this cannot prove Windows 10 compatibility.',
        'The elevated dedicated principal is denied local interactive and Remote Desktop logon; elevation is required for Windows TUN and route ownership.',
        'Runtime acceptance covers only this Windows Server 2022 host and does not replace Windows 10 evidence.'
    )
}
$outputPath = Join-Path $LabRoot 'evidence\harness-deployment-readiness.json'
Write-RuntimeAtomicJson -Value $report -Path $outputPath
$report | ConvertTo-Json -Depth 16
if ($report.result -ne 'READY_FOR_ACCEPTANCE') { exit 1 }
exit 0
