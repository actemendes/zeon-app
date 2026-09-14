[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeLab.Common.ps1')

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
if ([int]$request.schema_version -ne 2 -or [string]$request.controller_schema -cne 'zeon.remote-controller.v2' -or [string]$request.runtime_schema -cne 'zeon.windows-runtime.v1') { throw 'Unsupported runtime request schema.' }
$runId = [string]$request.run_id
Assert-RuntimeSafeId -Value $runId -Label 'run_id'
$allowedScenarios = @('preflight', 'connect', 's02', 's06', 'manual-proxy', 'auto-proxy', 'p03-r17', 'p04')
$allowedModes = @('system-proxy', 'tun', 'local-proxy')
$allowedIPv6Modes = @('ipv4_only', 'prefer_ipv4', 'prefer_ipv6', 'ipv6_only')
if ([string]$request.scenario -notin $allowedScenarios) { throw 'Scenario is outside the runtime allowlist.' }
if ([string]$request.mode -notin $allowedModes) { throw 'Network mode is outside the runtime allowlist.' }
if ([string]$request.ipv6_mode -notin $allowedIPv6Modes) { throw 'IPv6 mode is outside the runtime allowlist.' }
if ([string]$request.cleanup_policy -cne 'strict-restore-and-verify') { throw 'Unsupported cleanup policy.' }
if ([int]$request.execution_timeout_seconds -lt 3 -or [int]$request.execution_timeout_seconds -gt 7200) { throw 'Execution deadline is outside the finite allowlist.' }
if ([int]$request.controller_timeout_seconds -lt 60 -or [int]$request.controller_timeout_seconds -gt 10800) { throw 'Controller deadline is outside the finite allowlist.' }
if ([int]$request.s02_cycles -lt 1 -or [int]$request.s02_cycles -gt 10) { throw 'S02 cycle count is outside the documented bounded range.' }
if ([string]$request.cancel_phase -notin @('app-connecting', 'core-starting')) { throw 'S06 cancel phase is outside the allowlist.' }
if ([string]$request.version -notmatch '^\d+\.\d+\.\d+$' -or [int]$request.build_number -lt 1) { throw 'Invalid artifact version/build.' }
foreach ($field in @('artifact_sha256', 'executable_sha256', 'native_core_sha256', 'request_sha256')) {
    if ([string]$request.$field -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid $field." }
}
$requestHash = Get-RuntimeFileHash -Path $RequestPath
$requestForHash = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$requestForHash.request_sha256 = ('0' * 64)
$canonicalTemporary = Join-Path $env:TEMP ("zeon-request-hash-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($canonicalTemporary, (($requestForHash | ConvertTo-Json -Compress -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
    $canonicalHash = Get-RuntimeFileHash -Path $canonicalTemporary
} finally {
    Remove-Item -LiteralPath $canonicalTemporary -Force -ErrorAction SilentlyContinue
}
if ($canonicalHash -cne ([string]$request.request_sha256).ToLowerInvariant()) { throw 'Runtime request immutable hash mismatch.' }

$artifactDirectory = Join-Path $LabRoot ("artifacts\{0}\{1}" -f $request.version, [int]$request.build_number)
$artifactDirectory = Assert-RuntimePathWithin -Path $artifactDirectory -Root (Join-Path $LabRoot 'artifacts') -Label 'artifact directory'
$artifactFile = [string]$request.artifact_file
$buildManifestFile = [string]$request.build_manifest_file
if ([IO.Path]::GetFileName($artifactFile) -cne $artifactFile -or [IO.Path]::GetFileName($buildManifestFile) -cne $buildManifestFile) { throw 'Artifact file names must not contain a path.' }
$zipPath = Join-Path $artifactDirectory $artifactFile
$buildManifestPath = Join-Path $artifactDirectory $buildManifestFile
foreach ($path in @($zipPath, $buildManifestPath, (Join-Path $artifactDirectory 'artifact-manifest.json'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Published artifact input is missing: $path" }
}
if ((Get-RuntimeFileHash -Path $zipPath) -cne ([string]$request.artifact_sha256).ToLowerInvariant()) { throw 'Published artifact ZIP hash mismatch.' }
$buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
if (([string]$buildManifest.source_sha).ToLowerInvariant() -cne ([string]$request.source_sha).ToLowerInvariant() -or ([string]$buildManifest.artifact_sha256).ToLowerInvariant() -cne ([string]$request.artifact_sha256).ToLowerInvariant()) {
    throw 'Published build provenance does not match the request.'
}
if (([string]$buildManifest.executable_sha256).ToLowerInvariant() -cne ([string]$request.executable_sha256).ToLowerInvariant() -or ([string]$buildManifest.native_core_sha256).ToLowerInvariant() -cne ([string]$request.native_core_sha256).ToLowerInvariant()) {
    throw 'Published executable/core provenance does not match the request.'
}
if ([string]$request.scenario -ne 'preflight') {
    Assert-RuntimeSafeId -Value ([string]$request.fixture_id) -Label 'fixture_id'
    if ([string]$request.fixture_sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Connect request fixture hash is invalid.' }
    $fixturePath = Join-Path $env:ProgramData ("ZEON-LAB-Secrets\{0}.dpapi" -f $request.fixture_id)
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw 'Encrypted connect fixture is missing.' }
}

$queueDirectory = Join-Path $LabRoot 'state\runtime\queue'
$archiveDirectory = Join-Path $LabRoot 'state\runtime\archive'
$runDirectory = Join-Path $LabRoot ("evidence\runs\{0}" -f $runId)
$queuePath = Join-Path $queueDirectory ("{0}.request.json" -f $runId)
$activePath = Join-Path $LabRoot 'state\runtime\active-run.json'
if (Test-Path -LiteralPath $activePath) { throw 'A product runtime run is already active.' }
if (@(Get-ChildItem -LiteralPath $queueDirectory -Filter '*.request.json' -File -ErrorAction SilentlyContinue).Count -gt 0) { throw 'A product runtime run is already queued.' }
if ((Test-Path -LiteralPath $queuePath) -or (Test-Path -LiteralPath (Join-Path $archiveDirectory ("{0}.request.json" -f $runId))) -or (Test-Path -LiteralPath $runDirectory)) {
    throw 'run_id already exists and cannot be overwritten.'
}
New-Item -ItemType Directory -Path $runDirectory | Out-Null
Copy-Item -LiteralPath $RequestPath -Destination (Join-Path $runDirectory 'request.json')
$status = [ordered]@{
    schema_version = 2
    run_id = $runId
    scenario = [string]$request.scenario
    mode = [string]$request.mode
    status = 'queued'
    verdict = $null
    classification = $null
    queued_at = [string]$request.queued_at
    started_at = $null
    completed_at = $null
    deadline = $null
    pid = $null
    exit_code = $null
    main_window_handle = $null
    ui_created = $false
    previous_status = $null
    failure_reason = $null
    failure_detail = $null
    failure_type = $null
    listener_owner_verified = $null
    secret_scan_clean = $false
    safe_to_collect = $false
    runtime_identity = $null
    runtime_sid = $null
    cleanup_verified = $false
}
Write-RuntimeAtomicJson -Value $status -Path (Join-Path $runDirectory 'status.json')
Add-RuntimeEvent -EventsPath (Join-Path $runDirectory 'controller-events.jsonl') -RunId $runId -Event 'queued'
Move-Item -LiteralPath $RequestPath -Destination $queuePath
Start-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation'
$status | ConvertTo-Json -Depth 8
