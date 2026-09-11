[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ActiveRunPath,
    [Parameter(Mandatory = $true)][string]$ArmingPath,
    [Parameter(Mandatory = $true)][string]$ExpectedRunId,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')
Assert-RuntimeSafeId -Value $ExpectedRunId -Label 'run_id'
if (-not (Test-Path -LiteralPath $ActiveRunPath -PathType Leaf)) { throw 'Active run manifest is missing.' }
if (-not (Test-Path -LiteralPath $ArmingPath -PathType Leaf)) { throw 'One-time recovery arming manifest is missing.' }
$active = Get-Content -LiteralPath $ActiveRunPath -Raw | ConvertFrom-Json
$arming = Get-Content -LiteralPath $ArmingPath -Raw | ConvertFrom-Json
if ([string]$active.run_id -cne $ExpectedRunId -or [string]$arming.run_id -cne $ExpectedRunId) { throw 'Recovery run_id mismatch.' }
if (-not [bool]$arming.allow_apply -or [bool]$arming.consumed) { throw 'Recovery apply is not armed.' }
if ([string]$arming.active_run_path -cne $ActiveRunPath) { throw 'Recovery arming active path mismatch.' }
if ([datetime]::Parse([string]$arming.expires_at).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) { throw 'Recovery arming manifest expired.' }

$runDirectory = [string]$active.run_directory
$resultPath = Join-Path $runDirectory 'recovery-result.json'
$report = [ordered]@{
    schema_version = 1
    run_id = $ExpectedRunId
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    arming_consumed = $false
    stopped_processes = @()
    skipped_processes = @()
    proxy_restored = $false
    routes_restored = $false
    dns_restored = $false
    routes_equal = $false
    dns_equal = $false
    proxy_equal = $false
    sshd_restarted = $false
    reboot_scheduled = $false
    success = $false
    error = $null
}
try {
    $arming.consumed = $true
    $arming.consumed_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-RuntimeAtomicJson -Value $arming -Path $ArmingPath
    $report.arming_consumed = $true

    $owned = Stop-RuntimeOwnedProcesses -ProcessIds @($active.test_process_ids | ForEach-Object { [int]$_ }) -ApplicationRoot ([string]$active.application_root)
    $report.stopped_processes = @($owned.stopped)
    $report.skipped_processes = @($owned.skipped)

    $baseline = Get-Content -LiteralPath ([string]$active.baseline_path) -Raw | ConvertFrom-Json
    Restore-RuntimeProxyBaseline -Baseline $baseline
    $report.proxy_restored = $true
    $after = Get-RuntimeNetworkState -UserSid ([string]$baseline.user_sid)
    Write-RuntimeAtomicJson -Value $after -Path (Join-Path $runDirectory 'after-recovery-network.json')
    $comparison = Get-RuntimeStateComparison -Before $baseline -After $after
    $report.proxy_equal = [bool]$comparison.proxy_equal
    $report.routes_equal = [bool]$comparison.routes_equal
    $report.dns_equal = [bool]$comparison.dns_equal
    $report.routes_restored = [bool]$comparison.routes_equal
    $report.dns_restored = [bool]$comparison.dns_equal

    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd -and $sshd.Status -ne 'Running') {
        Start-Service -Name sshd
        $report.sshd_restarted = $true
    }
    $report.success = $report.proxy_equal -and $report.routes_equal -and $report.dns_equal -and $report.skipped_processes.Count -eq 0
} catch {
    $report.error = $_.Exception.Message
} finally {
    $report.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-RuntimeAtomicJson -Value $report -Path $resultPath
    Remove-Item -LiteralPath $ArmingPath -Force -ErrorAction SilentlyContinue
}
if (-not $report.success) { throw 'Run-scoped recovery did not restore and verify the complete baseline.' }
$report
