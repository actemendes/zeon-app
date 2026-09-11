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

$deploymentPath = Join-Path $LabRoot 'state\runtime\deployment.json'
$deployment = if (Test-Path -LiteralPath $deploymentPath) { Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json } else { $null }
Add-Check 'deployment_manifest' ($null -ne $deployment) $deploymentPath
$task = Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation' -ErrorAction SilentlyContinue
$watchdogTask = Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Watchdog' -ErrorAction SilentlyContinue
Add-Check 'runtime_task_present' ($null -ne $task) 'ZEON-LAB Runtime Validation'
Add-Check 'runtime_task_system' ($task -and $task.Principal.UserId -eq 'SYSTEM' -and $task.Principal.RunLevel -eq 'Highest') 'SYSTEM, highest'
Add-Check 'runtime_task_action' ($task -and [string]$task.Actions.Execute -match 'powershell' -and [string]$task.Actions.Arguments -eq '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1') 'fixed script action without request or secret arguments'
Add-Check 'watchdog_task_present' ($null -ne $watchdogTask) 'ZEON-LAB Runtime Watchdog'
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
    $selfTestId = 'recovery-noop-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $selfTestRoot = Join-Path $LabRoot ("temp\runtime-selftest\{0}" -f $selfTestId)
    New-Item -ItemType Directory -Path (Join-Path $selfTestRoot 'app') -Force | Out-Null
    try {
        $baselinePath = Join-Path $selfTestRoot 'baseline.json'
        $baseline = Get-RuntimeNetworkState -UserSid 'S-1-5-18'
        Write-RuntimeAtomicJson -Value $baseline -Path $baselinePath
        $activePath = Join-Path $selfTestRoot 'active.json'
        $armingPath = Join-Path $selfTestRoot 'arming.json'
        $active = [ordered]@{
            run_id = $selfTestId
            run_directory = $selfTestRoot
            application_root = (Join-Path $selfTestRoot 'app')
            baseline_path = $baselinePath
            test_process_ids = @()
        }
        $arming = [ordered]@{
            run_id = $selfTestId
            active_run_path = $activePath
            allow_apply = $true
            consumed = $false
            expires_at = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
        }
        Write-RuntimeAtomicJson -Value $active -Path $activePath
        Write-RuntimeAtomicJson -Value $arming -Path $armingPath
        & (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId $selfTestId -LabRoot $LabRoot | Out-Null
        $recoveryResult = Get-Content -LiteralPath (Join-Path $selfTestRoot 'recovery-result.json') -Raw | ConvertFrom-Json
        $noOp.passed = [bool]$recoveryResult.success -and -not [bool]$recoveryResult.sshd_restarted -and -not [bool]$recoveryResult.reboot_scheduled
        $noOp.result = $recoveryResult
    } finally {
        if (Test-Path -LiteralPath $selfTestRoot) { Remove-Item -LiteralPath $selfTestRoot -Force -Recurse }
    }
    Add-Check 'recovery_apply_noop' ([bool]$noOp.passed) 'run-scoped one-time arming; no process, network, sshd or reboot mutation'
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$report = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    result = if (@($checks | Where-Object { -not $_.passed }).Count -eq 0) { 'READY_FOR_HARNESS_RUN' } else { 'BLOCKED_BY_REMOTE_HARNESS' }
    hostname = $env:COMPUTERNAME
    operating_system = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR; architecture = $os.OSArchitecture }
    resources = [ordered]@{ logical_processors = $cs.NumberOfLogicalProcessors; total_ram_bytes = [uint64]$cs.TotalPhysicalMemory; free_ram_bytes = [uint64]$os.FreePhysicalMemory * 1KB; disk_free_bytes = [uint64]$disk.FreeSpace }
    controller_sha = [string]$manifest.controller_sha
    scripts = $manifest.files
    task = if ($task) { [ordered]@{ name = $task.TaskName; path = $task.TaskPath; principal = $task.Principal.UserId; run_level = $task.Principal.RunLevel.ToString(); execute = $task.Actions.Execute; arguments = $task.Actions.Arguments } } else { $null }
    watchdog = [ordered]@{ task = 'ZEON-LAB Runtime Watchdog'; default_mode = 'dry_run'; apply_gate = 'one-time run-scoped arming manifest'; no_op_apply = $noOp }
    artifact = $artifact
    checks = $checks
    limitations = @(
        'Actual OS is Windows Server 2022, not Windows 10; this cannot prove Windows 10 compatibility.',
        'System-proxy under SYSTEM validates the SYSTEM profile only, not the interactive Administrator profile.',
        'Only preflight and one bounded connect in system-proxy are enabled.'
    )
}
$outputPath = Join-Path $LabRoot 'evidence\harness-deployment-readiness.json'
Write-RuntimeAtomicJson -Value $report -Path $outputPath
$report | ConvertTo-Json -Depth 16
if ($report.result -ne 'READY_FOR_HARNESS_RUN') { exit 1 }
exit 0
