[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')

Assert-RuntimeSafeId -Value $RunId -Label 'run_id'
$activePath = Join-Path $LabRoot 'state\runtime\active-run.json'
if (-not (Test-Path -LiteralPath $activePath -PathType Leaf)) { throw 'No active runtime run exists.' }
$active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
if ([int]$active.schema_version -ne 2 -or [string]$active.run_id -cne $RunId) { throw 'Active runtime run does not match the requested run_id.' }
if ((Get-RuntimeFileHash -Path ([string]$active.baseline_path)) -cne [string]$active.baseline_sha256) { throw 'Active runtime baseline hash mismatch.' }

$armingPath = Join-Path $LabRoot ("state\runtime\arming\{0}.json" -f $RunId)
$arming = [ordered]@{
    schema_version = 2
    run_id = $RunId
    active_run_path = $activePath
    user_sid = [string]$active.user_sid
    baseline_sha256 = [string]$active.baseline_sha256
    heartbeat_path = [string]$active.heartbeat_path
    deadline = [string]$active.deadline
    pid_allowlist = @($active.test_process_ids)
    recovery_actions = @($active.recovery_actions)
    allow_apply = $true
    consumed = $false
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    expires_at = (Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
    manual_rearm = $true
    reboot_allowed = $false
}
Write-RuntimeAtomicJson -Value $arming -Path $armingPath
& (Join-Path $PSScriptRoot 'Invoke-RuntimeRecovery.ps1') -ActiveRunPath $activePath -ArmingPath $armingPath -ExpectedRunId $RunId -LabRoot $LabRoot | Out-Null
$recovery = Get-Content -LiteralPath (Join-Path ([string]$active.run_directory) 'recovery-result.json') -Raw | ConvertFrom-Json
if (-not [bool]$recovery.success) { throw 'Manual runtime recovery failed.' }

$statusPath = Join-Path ([string]$active.run_directory) 'status.json'
if (Test-Path -LiteralPath $statusPath) {
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    $status.previous_status = [string]$status.status
    $status.status = 'recovered'
    $status.verdict = 'FAIL'
    $status.classification = 'harness'
    $status.failure_reason = 'manual_recovery_requested'
    $status.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    $status.cleanup_verified = $true
    $status.secret_scan_clean = [bool]$recovery.secret_scan_clean
    $status.safe_to_collect = [bool]$recovery.secret_scan_clean
    Write-RuntimeAtomicJson -Value $status -Path $statusPath
}
Remove-Item -LiteralPath $activePath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath ([string]$active.baseline_path) -Force -ErrorAction SilentlyContinue
if ([string]$active.owned_state_path) { Remove-Item -LiteralPath ([string]$active.owned_state_path) -Force -ErrorAction SilentlyContinue }
$recovery | ConvertTo-Json -Depth 12
