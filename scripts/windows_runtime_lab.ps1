[CmdletBinding()]
param(
    [ValidateSet('preflight', 'connect')][string]$Scenario = 'preflight',
    [ValidateSet('system-proxy')][string]$NetworkMode = 'system-proxy',
    [string]$ArtifactPath,
    [string]$FixturePath,
    [string]$RunId = ("runtime-{0}-{1}" -f $Scenario, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')),
    [string]$EvidenceRoot = 'Z:\Zeon-Envelope\Temp\zeon-app-testing',
    [string]$RemoteHost = 'Administrator@89.111.171.67',
    [string]$IdentityFile = 'C:\Users\ZEON\.ssh\id_ed25519_zeon_ai',
    [ValidateRange(1, 45)][int]$ConnectTimeoutSeconds = 45,
    [ValidateRange(30, 600)][int]$BootstrapTimeoutSeconds = 240,
    [ValidateRange(15, 300)][int]$CleanupTimeoutSeconds = 90,
    [ValidateRange(60, 900)][int]$ScenarioTimeoutSeconds = 300,
    [ValidateRange(5, 30)][int]$ControllerTimeoutMinutes = 15,
    [switch]$PublishArtifact,
    [switch]$DeployHarness,
    [switch]$ApplyNoOpRecovery,
    [switch]$CollectOnly,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDirectory = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDirectory
$runtimeScripts = Join-Path $scriptDirectory 'windows_runtime_lab'
$allowedArtifactRoot = Join-Path $repoRoot 'out\installers\win'
$allowedEvidenceRoot = 'Z:\Zeon-Envelope\Temp'
$remoteLabRoot = 'C:\ZEON-LAB'

function Assert-PathWithin {
    param([string]$Path, [string]$Root, [string]$Label)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay below $resolvedRoot."
    }
    return $resolvedPath
}

function Assert-RunId([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') { throw 'RunId must contain 3-80 safe filename characters.' }
}

function Get-SshArguments {
    return @('-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=15', '-i', $IdentityFile)
}

function Invoke-RemoteCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    $output = & ssh.exe @(Get-SshArguments) $RemoteHost $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed with exit code $LASTEXITCODE. $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-RemotePowerShell {
    param([Parameter(Mandatory = $true)][string]$Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    return Invoke-RemoteCommand -Command "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -EncodedCommand $encoded"
}

function Copy-ToRemote {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$RemotePath, [switch]$Recurse)
    $arguments = @(Get-SshArguments)
    if ($Recurse) { $arguments += '-r' }
    & scp.exe @arguments $Source ("{0}:{1}" -f $RemoteHost, $RemotePath)
    if ($LASTEXITCODE -ne 0) { throw "SCP upload failed: $Source" }
}

function Copy-FromRemote {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$Destination)
    & scp.exe @(Get-SshArguments) ("{0}:{1}" -f $RemoteHost, $RemotePath) $Destination
    if ($LASTEXITCODE -ne 0) { throw "SCP download failed: $RemotePath" }
}

function Get-ArtifactMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = Assert-PathWithin -Path $Path -Root $allowedArtifactRoot -Label 'ArtifactPath'
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'Runtime artifact does not exist.' }
    $manifestPath = $resolved + '.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Runtime build manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.schema -ne 'zeon.windows-runtime-build.v1' -or [string]$manifest.build_type -ne 'windows-runtime-validation') { throw 'Unexpected runtime build provenance schema.' }
    if ([string]$manifest.version -notmatch '^(\d+\.\d+\.\d+)\+([1-9][0-9]*)$') { throw 'Runtime artifact version is invalid.' }
    $version = $Matches[1]
    $buildNumber = [int]$Matches[2]
    $actual = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    if ($actual -cne [string]$manifest.artifact_sha256) { throw 'Runtime artifact SHA-256 differs from its build manifest.' }
    return [ordered]@{
        path = $resolved
        manifest_path = $manifestPath
        manifest = $manifest
        version = $version
        build_number = $buildNumber
        artifact_sha256 = $actual.ToLowerInvariant()
        manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-ControllerSha {
    $sha = (& git.exe -C $repoRoot rev-parse HEAD).Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') { throw 'Unable to resolve controller implementation SHA.' }
    return $sha
}

function Publish-RemoteArtifact {
    param([Parameter(Mandatory = $true)]$Artifact)
    $destination = "$remoteLabRoot\artifacts\$($Artifact.version)\$($Artifact.build_number)"
    $exists = Invoke-RemotePowerShell -Script "[bool](Test-Path -LiteralPath '$destination') | ConvertTo-Json -Compress"
    if (($exists | ConvertFrom-Json) -eq $true) { throw "Remote build already exists and will not be overwritten: $destination" }
    $token = [guid]::NewGuid().ToString('N')
    $incoming = "$remoteLabRoot\temp\incoming\artifact-$token"
    try {
        Invoke-RemotePowerShell -Script "New-Item -ItemType Directory -Path '$incoming' -Force | Out-Null" | Out-Null
        Copy-ToRemote -Source $Artifact.path -RemotePath (($incoming + '\' + [IO.Path]::GetFileName($Artifact.path)) -replace '\\', '/')
        Copy-ToRemote -Source $Artifact.manifest_path -RemotePath (($incoming + '\' + [IO.Path]::GetFileName($Artifact.manifest_path)) -replace '\\', '/')
        $verify = @"
`$zip = '$incoming\$([IO.Path]::GetFileName($Artifact.path))'
`$manifest = '$incoming\$([IO.Path]::GetFileName($Artifact.manifest_path))'
if ((Get-FileHash -LiteralPath `$zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne '$($Artifact.artifact_sha256)') { throw 'Remote ZIP hash mismatch.' }
if ((Get-FileHash -LiteralPath `$manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne '$($Artifact.manifest_sha256)') { throw 'Remote provenance hash mismatch.' }
& '$remoteLabRoot\scripts\Publish-LabArtifact.ps1' -SourcePath '$incoming' -Version '$($Artifact.version)' -BuildNumber $($Artifact.build_number) | Out-Null
Get-Content -LiteralPath '$destination\artifact-manifest.json' -Raw
"@
        return Invoke-RemotePowerShell -Script $verify | ConvertFrom-Json
    } finally {
        Invoke-RemotePowerShell -Script "if (Test-Path -LiteralPath '$incoming') { Remove-Item -LiteralPath '$incoming' -Force -Recurse }" | Out-Null
    }
}

function Install-RemoteHarness {
    $required = @(
        'RuntimeLab.Common.ps1',
        'Protect-RuntimeFixture.ps1',
        'Queue-RuntimeRun.ps1',
        'Invoke-RuntimeRunner.ps1',
        'Invoke-RuntimeWatchdog.ps1',
        'Invoke-RuntimeRecovery.ps1',
        'Test-RuntimeHarness.ps1'
    )
    $stage = Join-Path 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB' ("runtime-harness-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        $files = @()
        foreach ($name in $required) {
            $source = Join-Path $runtimeScripts $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Remote runtime script is missing: $name" }
            Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name)
            $files += [ordered]@{ name = $name; sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        Copy-Item -LiteralPath (Join-Path $runtimeScripts 'Install-RuntimeHarness.ps1') -Destination (Join-Path $stage 'Install-RuntimeHarness.ps1')
        $deploymentManifest = [ordered]@{
            schema_version = 1
            created_at = [DateTime]::UtcNow.ToString('o')
            controller_sha = Get-ControllerSha
            files = $files
        }
        [IO.File]::WriteAllText((Join-Path $stage 'deployment-manifest.json'), (($deploymentManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $remoteParent = "$remoteLabRoot\temp\incoming"
        Invoke-RemotePowerShell -Script "New-Item -ItemType Directory -Path '$remoteParent' -Force | Out-Null" | Out-Null
        Copy-ToRemote -Source $stage -RemotePath (($remoteParent + '\') -replace '\\', '/') -Recurse
        $remoteStage = "$remoteParent\$([IO.Path]::GetFileName($stage))"
        try {
            $install = "& '$remoteStage\Install-RuntimeHarness.ps1' -SourceDirectory '$remoteStage' -LabRoot '$remoteLabRoot'"
            return Invoke-RemotePowerShell -Script $install | ConvertFrom-Json
        } finally {
            Invoke-RemotePowerShell -Script "if (Test-Path -LiteralPath '$remoteStage') { Remove-Item -LiteralPath '$remoteStage' -Force -Recurse }" | Out-Null
        }
    } finally {
        $resolvedStage = Assert-PathWithin -Path $stage -Root 'Z:\Zeon-Envelope\Temp' -Label 'Deployment staging'
        if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Force -Recurse }
    }
}

function Test-RemoteHarness {
    param($Artifact)
    $arguments = if ($Artifact) { "-Version '$($Artifact.version)' -BuildNumber $($Artifact.build_number)" } else { '' }
    if ($ApplyNoOpRecovery) { $arguments += ' -ApplyNoOpRecovery' }
    $output = Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Test-RuntimeHarness.ps1' $arguments -LabRoot '$remoteLabRoot'"
    $readinessRoot = 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\readiness'
    New-Item -ItemType Directory -Path $readinessRoot -Force | Out-Null
    $localReadiness = Join-Path $readinessRoot 'harness-deployment-readiness.json'
    Copy-FromRemote -RemotePath 'C:/ZEON-LAB/evidence/harness-deployment-readiness.json' -Destination $localReadiness
    return $output | ConvertFrom-Json
}

function New-RuntimeRequest {
    param([Parameter(Mandatory = $true)]$Artifact, [string]$FixtureId, [string]$FixtureSha256)
    $request = [ordered]@{
        schema_version = 1
        run_id = $RunId
        scenario = $Scenario
        mode = $NetworkMode
        version = $Artifact.version
        build_number = $Artifact.build_number
        artifact_file = [IO.Path]::GetFileName($Artifact.path)
        build_manifest_file = [IO.Path]::GetFileName($Artifact.manifest_path)
        artifact_sha256 = $Artifact.artifact_sha256
        executable_sha256 = ([string]$Artifact.manifest.executable_sha256).ToLowerInvariant()
        native_core_sha256 = ([string]$Artifact.manifest.native_core_sha256).ToLowerInvariant()
        source_sha = ([string]$Artifact.manifest.source_sha).ToLowerInvariant()
        controller_sha = Get-ControllerSha
        connect_timeout_seconds = $ConnectTimeoutSeconds
        bootstrap_timeout_seconds = $BootstrapTimeoutSeconds
        cleanup_timeout_seconds = $CleanupTimeoutSeconds
        scenario_timeout_seconds = $ScenarioTimeoutSeconds
        execution_timeout_seconds = $BootstrapTimeoutSeconds + $ScenarioTimeoutSeconds + $CleanupTimeoutSeconds + 120
        traffic_url = 'https://speed.cloudflare.com/__down?bytes=4096'
        fixture_id = $FixtureId
        fixture_sha256 = $FixtureSha256
        queued_at = [DateTime]::UtcNow.ToString('o')
        request_sha256 = ('0' * 64)
    }
    $hashPath = Join-Path 'Z:\Zeon-Envelope\Temp' ("runtime-request-hash-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($hashPath, (($request | ConvertTo-Json -Compress -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
        $request.request_sha256 = (Get-FileHash -LiteralPath $hashPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $hashPath -Force -ErrorAction SilentlyContinue
    }
    return $request
}

function Collect-RemoteRun {
    param([Parameter(Mandatory = $true)][string]$TargetRunId, [string]$FixtureForScan)
    Assert-RunId $TargetRunId
    $runDirectory = "$remoteLabRoot\evidence\runs\$TargetRunId"
    $statusJson = Invoke-RemotePowerShell -Script "Get-Content -LiteralPath '$runDirectory\status.json' -Raw"
    $status = $statusJson | ConvertFrom-Json
    if (-not [bool]$status.safe_to_collect) { throw 'Remote evidence did not pass the fixture/profile secret scan.' }
    $remoteArchive = "$remoteLabRoot\temp\exports\$TargetRunId.zip"
    $archiveHash = Invoke-RemotePowerShell -Script "if (Test-Path -LiteralPath '$remoteArchive') { Remove-Item -LiteralPath '$remoteArchive' -Force }; Compress-Archive -Path '$runDirectory\*' -DestinationPath '$remoteArchive' -CompressionLevel Optimal; (Get-FileHash -LiteralPath '$remoteArchive' -Algorithm SHA256).Hash.ToLowerInvariant()"
    $targetRoot = Assert-PathWithin -Path (Join-Path $EvidenceRoot $TargetRunId) -Root $EvidenceRoot -Label 'Run evidence'
    if (Test-Path -LiteralPath $targetRoot) { throw "Local run evidence already exists: $targetRoot" }
    New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    $localArchive = Join-Path $targetRoot 'evidence.zip'
    try {
        Copy-FromRemote -RemotePath (($remoteArchive) -replace '\\', '/') -Destination $localArchive
        $localHash = (Get-FileHash -LiteralPath $localArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($localHash -cne $archiveHash.Trim().ToLowerInvariant()) { throw 'Evidence archive SHA-256 mismatch.' }
        $expanded = Join-Path $targetRoot 'evidence'
        Expand-Archive -LiteralPath $localArchive -DestinationPath $expanded
        if ($FixtureForScan) {
            $fixtureText = [IO.File]::ReadAllText($FixtureForScan).Trim()
            $leak = $false
            foreach ($file in @(Get-ChildItem -LiteralPath $expanded -File -Recurse | Where-Object Extension -In @('.json','.jsonl','.log','.txt'))) {
                if ($fixtureText -and [IO.File]::ReadAllText($file.FullName).Contains($fixtureText)) { $leak = $true; break }
            }
            if ($leak) { throw 'Local evidence contains the fixture plaintext and must not be used.' }
        }
        return [ordered]@{ status = $status; local_root = $targetRoot; archive = $localArchive; archive_sha256 = $localHash; evidence = $expanded }
    } finally {
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteArchive' -Force -ErrorAction SilentlyContinue" | Out-Null
    }
}

Assert-RunId $RunId
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'Dedicated SSH identity file is missing.' }
$EvidenceRoot = Assert-PathWithin -Path $EvidenceRoot -Root $allowedEvidenceRoot -Label 'EvidenceRoot'
$requiredRemoteFiles = @(
    'Install-RuntimeHarness.ps1', 'RuntimeLab.Common.ps1', 'Protect-RuntimeFixture.ps1',
    'Queue-RuntimeRun.ps1', 'Invoke-RuntimeRunner.ps1', 'Invoke-RuntimeWatchdog.ps1',
    'Invoke-RuntimeRecovery.ps1', 'Test-RuntimeHarness.ps1'
)
foreach ($name in $requiredRemoteFiles) {
    $path = Join-Path $runtimeScripts $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Runtime harness source is missing: $name" }
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -ne 0) { throw "PowerShell parser errors in runtime harness source: $name" }
}

$artifact = if ($ArtifactPath) { Get-ArtifactMetadata -Path $ArtifactPath } else { $null }
if ($ValidateOnly) {
    [ordered]@{
        valid = $true
        remote_host = $RemoteHost
        transport = 'key-only SSH and SCP'
        scenarios = @('preflight', 'connect')
        modes = @('system-proxy')
        scheduled_task = '\ZEON-LAB\ZEON-LAB Runtime Validation'
        task_identity = 'SYSTEM'
        request_transport = 'validated immutable JSON'
        watchdog_default = 'dry_run'
        recovery_apply_gate = 'one-time run-scoped arming manifest'
        artifact = if ($artifact) { [ordered]@{ version = $artifact.manifest.version; source_sha = $artifact.manifest.source_sha; sha256 = $artifact.artifact_sha256 } } else { $null }
        uses_ui_automation = $false
    }
    return
}

if ($CollectOnly) {
    Collect-RemoteRun -TargetRunId $RunId -FixtureForScan $FixturePath
    return
}

$publicationResult = $null
if ($PublishArtifact) {
    if (-not $artifact) { throw 'ArtifactPath is required with PublishArtifact.' }
    $publicationResult = Publish-RemoteArtifact -Artifact $artifact
}
$deploymentResult = $null
$readinessResult = $null
if ($DeployHarness) {
    $deploymentResult = Install-RemoteHarness
    $readinessResult = Test-RemoteHarness -Artifact $artifact
} elseif ($ApplyNoOpRecovery) {
    $readinessResult = Test-RemoteHarness -Artifact $artifact
}

$explicitScenario = $PSBoundParameters.ContainsKey('Scenario')
if (($PublishArtifact -or $DeployHarness -or $ApplyNoOpRecovery) -and -not $explicitScenario) {
    [ordered]@{ publication = $publicationResult; deployment = $deploymentResult; readiness = $readinessResult }
    return
}

if (-not $artifact) { throw 'ArtifactPath is required to queue a runtime run.' }
if ($Scenario -eq 'connect' -and -not $FixturePath) { throw 'FixturePath is required for connect.' }
$fixtureId = $null
$fixtureHash = $null
$remoteFixtureTransfer = $null
if ($FixturePath) {
    $FixturePath = Assert-PathWithin -Path $FixturePath -Root 'Z:\Zeon-Envelope\Temp' -Label 'FixturePath'
    if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) { throw 'Fixture file is missing.' }
    $fixtureHash = (Get-FileHash -LiteralPath $FixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $fixtureId = 'fixture-' + [guid]::NewGuid().ToString('N')
    $remoteFixtureTransfer = "$env:SystemRoot\Temp\ZEON-LAB-fixture-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-ToRemote -Source $FixturePath -RemotePath (($remoteFixtureTransfer) -replace '\\', '/')
        Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Protect-RuntimeFixture.ps1' -SourcePath '$remoteFixtureTransfer' -FixtureId '$fixtureId' -ExpectedSha256 '$fixtureHash'" | Out-Null
    } finally {
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteFixtureTransfer' -Force -ErrorAction SilentlyContinue" | Out-Null
    }
}

$request = New-RuntimeRequest -Artifact $artifact -FixtureId $fixtureId -FixtureSha256 $fixtureHash
$requestRoot = 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\requests'
New-Item -ItemType Directory -Path $requestRoot -Force | Out-Null
$requestPath = Join-Path $requestRoot ("{0}.request.json" -f $RunId)
if (Test-Path -LiteralPath $requestPath) { throw 'Local immutable request already exists.' }
[IO.File]::WriteAllText($requestPath, (($request | ConvertTo-Json -Compress -Depth 12) + "`n"), [Text.UTF8Encoding]::new($false))
$remoteRequest = "$remoteLabRoot\temp\incoming\$RunId.request.json"
try {
    Copy-ToRemote -Source $requestPath -RemotePath (($remoteRequest) -replace '\\', '/')
    Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Queue-RuntimeRun.ps1' -RequestPath '$remoteRequest' -LabRoot '$remoteLabRoot'" | Out-Null
} catch {
    Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteRequest' -Force -ErrorAction SilentlyContinue" | Out-Null
    throw
}

$queueSessionClosedAt = [DateTime]::UtcNow
$freshSessionObserved = $false
$terminal = @('completed', 'failed', 'timed_out', 'recovered')
$controllerDeadline = [DateTime]::UtcNow.AddMinutes($ControllerTimeoutMinutes)
do {
    $statusJson = Invoke-RemotePowerShell -Script "Get-Content -LiteralPath '$remoteLabRoot\evidence\runs\$RunId\status.json' -Raw"
    $status = $statusJson | ConvertFrom-Json
    $freshSessionObserved = $true
    if ([string]$status.status -in $terminal) { break }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $controllerDeadline)
if ([string]$status.status -notin $terminal) { throw "Runtime did not reach a terminal state within $ControllerTimeoutMinutes minutes; the detached task/watchdog remain authoritative." }

$collected = Collect-RemoteRun -TargetRunId $RunId -FixtureForScan $FixturePath
$postCheck = Invoke-RemotePowerShell -Script "`$p=@(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -Match '^(ZEON|ZEONCli)$'); [ordered]@{hostname=`$env:COMPUTERNAME;sshd=(Get-Service sshd).Status.ToString();zeon_process_count=`$p.Count} | ConvertTo-Json -Compress" | ConvertFrom-Json
$controllerResult = [ordered]@{
    schema_version = 1
    run_id = $RunId
    scenario = $Scenario
    status = [string]$collected.status.status
    source_sha = [string]$artifact.manifest.source_sha
    controller_sha = [string]$request.controller_sha
    artifact_sha256 = $artifact.artifact_sha256
    fixture_sha256 = $fixtureHash
    queue_session_closed_at = $queueSessionClosedAt.ToString('o')
    observed_from_fresh_ssh_session = $freshSessionObserved
    post_run_ssh = $postCheck
    evidence_archive_sha256 = $collected.archive_sha256
    local_evidence = $collected.evidence
}
[IO.File]::WriteAllText((Join-Path $collected.local_root 'controller-result.json'), (($controllerResult | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
$controllerResult
