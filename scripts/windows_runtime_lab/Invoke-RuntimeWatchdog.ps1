[CmdletBinding()]
param([string]$LabRoot = 'C:\ZEON-LAB')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')

$now = (Get-Date).ToUniversalTime()
$activePath = Join-Path $LabRoot 'state\runtime\active-run.json'
$report = [ordered]@{
    schema_version = 2
    checked_at = $now.ToString('o')
    active_run_present = Test-Path -LiteralPath $activePath
    mode = 'dry_run'
    deadline_exceeded = $false
    heartbeat_stale = $false
    arming_valid = $false
    recovery_invoked = $false
    planned_actions = @()
    reboot_allowed = $false
    error = $null
}
try {
    if ($report.active_run_present) {
        $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
        $runId = [string]$active.run_id
        Assert-RuntimeSafeId -Value $runId -Label 'run_id'
        $deadline = [datetime]::Parse([string]$active.deadline).ToUniversalTime()
        $report.deadline_exceeded = $now -ge $deadline
        $heartbeatPath = [string]$active.heartbeat_path
        if (Test-Path -LiteralPath $heartbeatPath) {
            $heartbeat = Get-Content -LiteralPath $heartbeatPath -Raw | ConvertFrom-Json
            $heartbeatAt = [datetime]::Parse([string]$heartbeat.utc).ToUniversalTime()
            $report.heartbeat_stale = ($now - $heartbeatAt).TotalSeconds -gt 30
        } else {
            $report.heartbeat_stale = $true
        }
        if ($report.deadline_exceeded -or $report.heartbeat_stale) {
            $report.planned_actions = @(
                'terminate only run-recorded processes whose executable remains under the run application root',
                'restore only the run-recorded dedicated-user WinINet and global WinHTTP delta',
                'verify routes and DNS exactly match the run baseline without touching foreign state',
                'start sshd only if stopped',
                'remove only the dedicated runtime principal ZEON roaming state',
                'never reboot automatically'
            )
            $armingPath = Join-Path $LabRoot ("state\runtime\arming\{0}.json" -f $runId)
            if (Test-Path -LiteralPath $armingPath) {
                $arming = Get-Content -LiteralPath $armingPath -Raw | ConvertFrom-Json
                $report.arming_valid = [int]$active.schema_version -eq 2 -and [int]$arming.schema_version -eq 2 -and [string]$arming.run_id -ceq $runId -and [bool]$arming.allow_apply -and -not [bool]$arming.consumed -and [string]$arming.active_run_path -ceq $activePath -and [string]$arming.user_sid -ceq [string]$active.user_sid -and [string]$arming.baseline_sha256 -ceq [string]$active.baseline_sha256 -and [datetime]::Parse([string]$arming.expires_at).ToUniversalTime() -ge $now
            }
            if ($report.arming_valid) {
                $report.mode = 'apply'
                & (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId $runId -LabRoot $LabRoot
                $report.recovery_invoked = $true
                $recoveryResult = Get-Content -LiteralPath (Join-Path ([string]$active.run_directory) 'recovery-result.json') -Raw | ConvertFrom-Json
                $statusPath = Join-Path ([string]$active.run_directory) 'status.json'
                if (Test-Path -LiteralPath $statusPath) {
                    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                    $request = Get-Content -LiteralPath (Join-Path ([string]$active.run_directory) 'request.json') -Raw | ConvertFrom-Json
                    $status.previous_status = [string]$status.status
                    $status.status = 'recovered'
                    $status.verdict = if ([bool]$request.expected_timeout_drill -and [bool]$recoveryResult.success) { 'PASS' } else { 'FAIL' }
                    $status.classification = if ([bool]$request.expected_timeout_drill) { 'harness-drill' } else { 'harness' }
                    $status.completed_at = (Get-Date).ToUniversalTime().ToString('o')
                    $status.cleanup_verified = [bool]$recoveryResult.success
                    $status.secret_scan_clean = [bool]$recoveryResult.secret_scan_clean
                    $status.safe_to_collect = [bool]$recoveryResult.success -and [bool]$recoveryResult.secret_scan_clean
                    Write-RuntimeAtomicJson -Value $status -Path $statusPath
                }
                Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath ([string]$active.baseline_path) -Force -ErrorAction SilentlyContinue
                if ([string]$active.owned_state_path) { Remove-Item -LiteralPath ([string]$active.owned_state_path) -Force -ErrorAction SilentlyContinue }
            }
        }
    }
} catch {
    $report.error = $_.Exception.Message
}
$report.completed_at = (Get-Date).ToUniversalTime().ToString('o')
$logPath = Join-Path $LabRoot ("logs\recovery\runtime-watchdog-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-RuntimeAtomicJson -Value $report -Path $logPath
Write-RuntimeAtomicJson -Value $report -Path (Join-Path $LabRoot 'state\runtime\watchdog-last.json')
if ($report.error) { exit 1 }
exit 0
