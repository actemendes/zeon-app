[CmdletBinding()]
param(
    [ValidateSet('preflight', 'connect', 's02', 's06', 'manual-proxy', 'auto-proxy')][string]$Scenario = 'preflight',
    [ValidateSet('system-proxy', 'tun', 'local-proxy')][string]$NetworkMode = 'system-proxy',
    [string]$ArtifactPath,
    [string]$FixtureId = 'zeon-authorized',
    [string]$RunId = ("runtime-{0}-{1}" -f $Scenario, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')),
    [string]$EvidenceRoot = 'Z:\Zeon-Envelope\Temp\zeon-app-testing',
    [string]$RemoteHost = 'Administrator@89.111.171.67',
    [string]$IdentityFile = 'C:\Users\ZEON\.ssh\id_ed25519_zeon_ai',
    [string[]]$TrafficUrls = @('https://speed.cloudflare.com/__down?bytes=4096', 'https://captive.apple.com/hotspot-detect.html'),
    [string]$BackendHealthUrl = 'https://api.zeon-vps.online/health',
    [ValidateRange(1, 45)][int]$ConnectTimeoutSeconds = 45,
    [ValidateRange(30, 600)][int]$BootstrapTimeoutSeconds = 240,
    [ValidateRange(15, 300)][int]$CleanupTimeoutSeconds = 90,
    [ValidateRange(0, 7200)][int]$ScenarioTimeoutSeconds = 0,
    [ValidateRange(1, 10)][int]$S02Cycles = 1,
    [ValidateSet('app-connecting', 'core-starting')][string]$CancelPhase = 'core-starting',
    [string]$ManualProxyTag,
    [ValidateRange(1, 180)][int]$ControllerTimeoutMinutes = 20,
    [switch]$PublishArtifact,
    [switch]$DeployHarness,
    [switch]$ApplyNoOpRecovery,
    [switch]$EnrollFixture,
    [switch]$FixtureSelfTest,
    [switch]$Detach,
    [switch]$CollectOnly,
    [switch]$Status,
    [switch]$ListRuns,
    [ValidateRange(1, 100)][int]$ListLimit = 20,
    [switch]$Recover,
    [switch]$TimeoutDrill,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http

$scriptDirectory = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDirectory
$runtimeScripts = Join-Path $scriptDirectory 'windows_runtime_lab'
$allowedArtifactRoot = Join-Path $repoRoot 'out\installers\win'
$allowedEvidenceRoot = 'Z:\Zeon-Envelope\Temp'
$remoteLabRoot = 'C:\ZEON-LAB'
$fixtureVaultRoot = 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\fixture-vault'
$controllerSchema = 'zeon.remote-controller.v2'
$runtimeSchema = 'zeon.windows-runtime.v1'

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

function Assert-HttpsUrl([string]$Value, [string[]]$AllowedHosts) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or -not $uri.Host -or $uri.Port -ne 443 -or $uri.UserInfo) {
        throw 'TrafficUrl must be an absolute HTTPS URL.'
    }
    if ($uri.Host.ToLowerInvariant() -notin $AllowedHosts) { throw 'HTTPS target host is outside the runtime allowlist.' }
}

function Set-LocalSecretAcl([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    $expectedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    $currentAcl = Get-Acl -LiteralPath $Path
    $currentRules = @($currentAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $unexpectedRules = @($currentRules | Where-Object {
        $_.IdentityReference.Value -notin $expectedSids -or
        $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl
    })
    $missingSids = @($expectedSids | Where-Object { $_ -notin @($currentRules.IdentityReference.Value) })
    if ($unexpectedRules.Count -eq 0 -and $missingSids.Count -eq 0) { return }
    $acl = if ($item.PSIsContainer) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($identity in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]'S-1-5-18', [Security.Principal.SecurityIdentifier]'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-LocalSecretBytes([byte[]]$Bytes) {
    return [Security.Cryptography.ProtectedData]::Protect($Bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Unprotect-LocalSecretBytes([byte[]]$Bytes) {
    return [Security.Cryptography.ProtectedData]::Unprotect($Bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Initialize-LocalFixtureVault {
    Assert-RunId $FixtureId
    New-Item -ItemType Directory -Path $fixtureVaultRoot -Force | Out-Null
    Set-LocalSecretAcl -Path $fixtureVaultRoot
    $secureSource = Read-Host 'Fixture source URL (stored only as CurrentUser DPAPI)' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSource)
    try {
        $sourceUrl = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $sourceUri = $null
        if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Host -cne 'zeon-vps.link' -or $sourceUri.AbsolutePath -notmatch '^/open/[0-9]+$' -or $sourceUri.Query -or $sourceUri.Fragment -or $sourceUri.UserInfo) {
            throw 'Fixture source is outside the approved ZEON open-profile endpoint shape.'
        }
        $sourceBytes = [Text.Encoding]::UTF8.GetBytes($sourceUrl)
        try {
            $protected = Protect-LocalSecretBytes -Bytes $sourceBytes
            $sourcePath = Join-Path $fixtureVaultRoot ("{0}.source.dpapi" -f $FixtureId)
            [IO.File]::WriteAllBytes($sourcePath, $protected)
            Set-LocalSecretAcl -Path $sourcePath
            Remove-Item -LiteralPath (Join-Path $fixtureVaultRoot ("{0}.profile.dpapi" -f $FixtureId)) -Force -ErrorAction SilentlyContinue
        } finally {
            [Array]::Clear($sourceBytes, 0, $sourceBytes.Length)
        }
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if ($secureSource) { $secureSource.Dispose() }
        $sourceUrl = $null
    }
    return [ordered]@{ enrolled = $true; fixture_id = $FixtureId; storage = 'DPAPI CurrentUser'; source = 'approved ZEON open-profile endpoint' }
}

function New-LocalFixtureTransfer {
    Assert-RunId $FixtureId
    $sourcePath = Join-Path $fixtureVaultRoot ("{0}.source.dpapi" -f $FixtureId)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'Fixture source is not enrolled. Run once with -EnrollFixture in an interactive PowerShell.' }
    $profilePath = Join-Path $fixtureVaultRoot ("{0}.profile.dpapi" -f $FixtureId)
    $sourceBytes = $null
    $sourceUrl = $null
    $profileBytes = $null
    $transferPath = $null
    $transferReady = $false
    try {
        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            $profileBytes = Unprotect-LocalSecretBytes -Bytes ([IO.File]::ReadAllBytes($profilePath))
        } else {
            $sourceBytes = Unprotect-LocalSecretBytes -Bytes ([IO.File]::ReadAllBytes($sourcePath))
            $sourceUrl = [Text.Encoding]::UTF8.GetString($sourceBytes)
            $client = New-Object Net.Http.HttpClient
            $client.Timeout = [TimeSpan]::FromSeconds(30)
            try { $profileBytes = $client.GetByteArrayAsync($sourceUrl).GetAwaiter().GetResult() } finally { $client.Dispose() }
            if (-not $profileBytes -or $profileBytes.Length -lt 16 -or $profileBytes.Length -gt 4MB) { throw 'Downloaded fixture size is outside the bounded range.' }
            [IO.File]::WriteAllBytes($profilePath, (Protect-LocalSecretBytes -Bytes $profileBytes))
            Set-LocalSecretAcl -Path $profilePath
        }
        if (-not $profileBytes -or $profileBytes.Length -lt 16 -or $profileBytes.Length -gt 4MB) { throw 'Cached fixture size is outside the bounded range.' }
        $transferRoot = 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\fixture-transfer'
        New-Item -ItemType Directory -Path $transferRoot -Force | Out-Null
        Set-LocalSecretAcl -Path $transferRoot
        $transferPath = Join-Path $transferRoot ("{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllBytes($transferPath, $profileBytes)
        Set-LocalSecretAcl -Path $transferPath
        $transferReady = $true
        return [ordered]@{
            path = $transferPath
            sha256 = (Get-FileHash -LiteralPath $transferPath -Algorithm SHA256).Hash.ToLowerInvariant()
            opaque_id = $FixtureId
            remote_id = 'fixture-' + [guid]::NewGuid().ToString('N')
        }
    } finally {
        if (-not $transferReady -and $transferPath) { Remove-Item -LiteralPath $transferPath -Force -ErrorAction SilentlyContinue }
        if ($sourceBytes) { [Array]::Clear($sourceBytes, 0, $sourceBytes.Length) }
        if ($profileBytes) { [Array]::Clear($profileBytes, 0, $profileBytes.Length) }
        $sourceUrl = $null
    }
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
        'Invoke-RuntimeManualRecovery.ps1',
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

function Get-ScenarioTimeoutSeconds {
    if ($ScenarioTimeoutSeconds -gt 0) { return $ScenarioTimeoutSeconds }
    return ([ordered]@{
        preflight = 120
        connect = 240
        s02 = 600
        s06 = 480
        'manual-proxy' = 360
        'auto-proxy' = 360
    })[$Scenario]
}

function New-RuntimeRequest {
    param([Parameter(Mandatory = $true)]$Artifact, [string]$RemoteFixtureId, [string]$FixtureSha256)
    $scenarioTimeout = Get-ScenarioTimeoutSeconds
    $executionTimeout = $BootstrapTimeoutSeconds + $scenarioTimeout + $CleanupTimeoutSeconds + 120
    if ($TimeoutDrill) { $executionTimeout = 3 }
    $request = [ordered]@{
        schema_version = 2
        controller_schema = $controllerSchema
        runtime_schema = $runtimeSchema
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
        scenario_timeout_seconds = $scenarioTimeout
        execution_timeout_seconds = $executionTimeout
        controller_timeout_seconds = $ControllerTimeoutMinutes * 60
        cleanup_policy = 'strict-restore-and-verify'
        traffic_urls = @($TrafficUrls)
        backend_health_url = $BackendHealthUrl
        fixture_opaque_id = if ($RemoteFixtureId) { $FixtureId } else { $null }
        fixture_id = $RemoteFixtureId
        fixture_sha256 = $FixtureSha256
        s02_cycles = $S02Cycles
        cancel_phase = $CancelPhase
        manual_proxy_tag = $ManualProxyTag
        expected_timeout_drill = [bool]$TimeoutDrill
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

function Get-RemoteRunStatus([string]$TargetRunId) {
    Assert-RunId $TargetRunId
    $statusPath = "$remoteLabRoot\evidence\runs\$TargetRunId\status.json"
    return Invoke-RemotePowerShell -Script "if (-not (Test-Path -LiteralPath '$statusPath' -PathType Leaf)) { throw 'Runtime status does not exist.' }; Get-Content -LiteralPath '$statusPath' -Raw" | ConvertFrom-Json
}

function Collect-RemoteRun {
    param([Parameter(Mandatory = $true)][string]$TargetRunId)
    $remoteStatus = Get-RemoteRunStatus -TargetRunId $TargetRunId
    if (-not [bool]$remoteStatus.safe_to_collect) { throw 'Remote evidence did not pass the fixture/profile secret scan.' }
    $runDirectory = "$remoteLabRoot\evidence\runs\$TargetRunId"
    $remoteArchive = "$remoteLabRoot\temp\exports\$TargetRunId.zip"
    $archiveHash = Invoke-RemotePowerShell -Script "New-Item -ItemType Directory -Path '$remoteLabRoot\temp\exports' -Force | Out-Null; if (Test-Path -LiteralPath '$remoteArchive') { Remove-Item -LiteralPath '$remoteArchive' -Force }; Compress-Archive -Path '$runDirectory\*' -DestinationPath '$remoteArchive' -CompressionLevel Optimal; (Get-FileHash -LiteralPath '$remoteArchive' -Algorithm SHA256).Hash.ToLowerInvariant()"
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
        $secretPattern = '(?i)(vless|vmess|trojan|ss|hysteria2|tuic)://|https://zeon-vps\.link/open/[0-9]+'
        foreach ($file in @(Get-ChildItem -LiteralPath $expanded -File -Recurse | Where-Object Extension -In @('.json','.jsonl','.log','.txt','.fixture'))) {
            if ([IO.File]::ReadAllText($file.FullName) -match $secretPattern) { throw 'Local evidence contains a profile/source secret pattern and must not be used.' }
        }
        return [ordered]@{ status = $remoteStatus; local_root = $targetRoot; archive = $localArchive; archive_sha256 = $localHash; evidence = $expanded }
    } finally {
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteArchive' -Force -ErrorAction SilentlyContinue" | Out-Null
    }
}

function Invoke-FixtureSelfTest {
    $transfer = New-LocalFixtureTransfer
    $remoteTransfer = "$env:SystemRoot\Temp\ZEON-LAB-fixture-$([guid]::NewGuid().ToString('N')).tmp"
    $remoteEncrypted = "$env:ProgramData\ZEON-LAB-Secrets\$($transfer.remote_id).dpapi"
    try {
        Copy-ToRemote -Source $transfer.path -RemotePath (($remoteTransfer) -replace '\\', '/')
        Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Protect-RuntimeFixture.ps1' -SourcePath '$remoteTransfer' -FixtureId '$($transfer.remote_id)' -ExpectedSha256 '$($transfer.sha256)' | Out-Null" | Out-Null
    } finally {
        Remove-Item -LiteralPath $transfer.path -Force -ErrorAction SilentlyContinue
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteTransfer' -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '$remoteEncrypted' -Force -ErrorAction SilentlyContinue" | Out-Null
    }
    $cleanup = Invoke-RemotePowerShell -Script "[ordered]@{transfer_absent=(-not (Test-Path -LiteralPath '$remoteTransfer')); encrypted_absent=(-not (Test-Path -LiteralPath '$remoteEncrypted'))} | ConvertTo-Json -Compress" | ConvertFrom-Json
    if (-not [bool]$cleanup.transfer_absent -or -not [bool]$cleanup.encrypted_absent) { throw 'Fixture injection self-test cleanup failed.' }
    $result = [ordered]@{
        schema_version = 1
        generated_at = [DateTime]::UtcNow.ToString('o')
        fixture_id = $FixtureId
        injection = 'PASS'
        cleanup = 'PASS'
        sha256 = $transfer.sha256
        plaintext_retained = $false
        controller_sha = Get-ControllerSha
    }
    $readinessRoot = 'Z:\Zeon-Envelope\Temp\ZEON-W10-LAB\readiness'
    New-Item -ItemType Directory -Path $readinessRoot -Force | Out-Null
    $localResult = Join-Path $readinessRoot 'fixture-self-test.json'
    [IO.File]::WriteAllText($localResult, (($result | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $encodedResult = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 6)))
    Invoke-RemotePowerShell -Script "`$bytes=[Convert]::FromBase64String('$encodedResult'); [IO.File]::WriteAllBytes('$remoteLabRoot\evidence\fixture-self-test.json', `$bytes)" | Out-Null
    return $result
}

if ($EnrollFixture) {
    Initialize-LocalFixtureVault
    return
}

Assert-RunId $RunId
foreach ($trafficUrl in $TrafficUrls) { Assert-HttpsUrl -Value $trafficUrl -AllowedHosts @('speed.cloudflare.com', 'captive.apple.com') }
Assert-HttpsUrl -Value $BackendHealthUrl -AllowedHosts @('api.zeon-vps.online')
if ($ManualProxyTag -and $ManualProxyTag -notmatch '^[A-Za-z0-9._-]{1,80}$') { throw 'ManualProxyTag contains unsupported characters.' }
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'Dedicated SSH identity file is missing.' }
$EvidenceRoot = Assert-PathWithin -Path $EvidenceRoot -Root $allowedEvidenceRoot -Label 'EvidenceRoot'
$requiredRemoteFiles = @(
    'Install-RuntimeHarness.ps1', 'RuntimeLab.Common.ps1', 'Protect-RuntimeFixture.ps1',
    'Queue-RuntimeRun.ps1', 'Invoke-RuntimeRunner.ps1', 'Invoke-RuntimeWatchdog.ps1',
    'Invoke-RuntimeRecovery.ps1', 'Invoke-RuntimeManualRecovery.ps1', 'Test-RuntimeHarness.ps1'
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
        schema = $controllerSchema
        remote_host = $RemoteHost
        transport = 'key-only SSH and SCP'
        scenarios = @('preflight', 'connect', 's02', 's06', 'manual-proxy', 'auto-proxy')
        modes = @('system-proxy', 'tun', 'local-proxy')
        scheduled_task = '\ZEON-LAB\ZEON-LAB Runtime Validation'
        task_identity = 'dedicated non-interactive local test principal'
        watchdog_identity = 'SYSTEM'
        request_transport = 'validated immutable JSON v2'
        watchdog_default = 'observe; apply only with a one-time run-scoped manifest'
        recovery = 'delta restore with ownership checks; no reboot'
        operations = @('publish', 'deploy', 'fixture-self-test', 'detach', 'status', 'list-runs', 'collect', 'recover', 'timeout-drill')
        artifact = if ($artifact) { [ordered]@{ version = $artifact.manifest.version; source_sha = $artifact.manifest.source_sha; sha256 = $artifact.artifact_sha256 } } else { $null }
        uses_ui_automation = $false
    }
    return
}

if ($Status) { Get-RemoteRunStatus -TargetRunId $RunId; return }
if ($ListRuns) {
    $listScript = "Get-ChildItem -LiteralPath '$remoteLabRoot\evidence\runs' -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $ListLimit | ForEach-Object { `$p=Join-Path `$_.FullName 'status.json'; if (Test-Path -LiteralPath `$p) { `$s=Get-Content -LiteralPath `$p -Raw | ConvertFrom-Json; [ordered]@{run_id=[string]`$s.run_id;scenario=[string]`$s.scenario;mode=[string]`$s.mode;status=[string]`$s.status;verdict=[string]`$s.verdict;classification=[string]`$s.classification;completed_at=[string]`$s.completed_at;cleanup_verified=[bool]`$s.cleanup_verified;safe_to_collect=[bool]`$s.safe_to_collect} } } | ConvertTo-Json -Depth 4"
    $json = Invoke-RemotePowerShell -Script $listScript
    if ($json) { $json | ConvertFrom-Json } else { @() }
    return
}
if ($Recover) {
    Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Invoke-RuntimeManualRecovery.ps1' -RunId '$RunId' -LabRoot '$remoteLabRoot'" | ConvertFrom-Json
    return
}
if ($CollectOnly) { Collect-RemoteRun -TargetRunId $RunId; return }
if ($FixtureSelfTest) { Invoke-FixtureSelfTest; return }

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
if ($TimeoutDrill -and $Scenario -ne 'preflight') { throw 'TimeoutDrill is intentionally limited to preflight.' }

$fixtureTransfer = $null
$remoteFixtureTransfer = $null
$remoteFixtureId = $null
$fixtureHash = $null
if ($Scenario -ne 'preflight') {
    $fixtureTransfer = New-LocalFixtureTransfer
    $remoteFixtureId = [string]$fixtureTransfer.remote_id
    $fixtureHash = [string]$fixtureTransfer.sha256
    $remoteFixtureTransfer = "$env:SystemRoot\Temp\ZEON-LAB-fixture-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-ToRemote -Source $fixtureTransfer.path -RemotePath (($remoteFixtureTransfer) -replace '\\', '/')
        Invoke-RemotePowerShell -Script "& '$remoteLabRoot\scripts\runtime\Protect-RuntimeFixture.ps1' -SourcePath '$remoteFixtureTransfer' -FixtureId '$remoteFixtureId' -ExpectedSha256 '$fixtureHash' | Out-Null" | Out-Null
    } catch {
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$env:ProgramData\ZEON-LAB-Secrets\$remoteFixtureId.dpapi' -Force -ErrorAction SilentlyContinue" | Out-Null
        throw
    } finally {
        Remove-Item -LiteralPath $fixtureTransfer.path -Force -ErrorAction SilentlyContinue
        Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteFixtureTransfer' -Force -ErrorAction SilentlyContinue" | Out-Null
    }
}

$request = New-RuntimeRequest -Artifact $artifact -RemoteFixtureId $remoteFixtureId -FixtureSha256 $fixtureHash
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
    Invoke-RemotePowerShell -Script "Remove-Item -LiteralPath '$remoteRequest' -Force -ErrorAction SilentlyContinue; if ('$remoteFixtureId') { Remove-Item -LiteralPath '$env:ProgramData\ZEON-LAB-Secrets\$remoteFixtureId.dpapi' -Force -ErrorAction SilentlyContinue }" | Out-Null
    throw
}

$queueSessionClosedAt = [DateTime]::UtcNow
if ($Detach) {
    [ordered]@{ schema_version = 2; run_id = $RunId; status = 'queued'; detached = $true; queue_session_closed_at = $queueSessionClosedAt.ToString('o'); fixture_sha256 = $fixtureHash }
    return
}

$freshSessionObserved = $false
$terminal = @('completed', 'failed', 'timed_out', 'recovered')
$controllerDeadline = [DateTime]::UtcNow.AddMinutes($ControllerTimeoutMinutes)
$runStatus = $null
do {
    $runStatus = Get-RemoteRunStatus -TargetRunId $RunId
    $freshSessionObserved = $true
    if ([string]$runStatus.status -in $terminal) { break }
    Start-Sleep -Seconds 5
} while ([DateTime]::UtcNow -lt $controllerDeadline)
if (-not $runStatus -or [string]$runStatus.status -notin $terminal) { throw "Runtime did not reach a terminal state within $ControllerTimeoutMinutes minutes; the detached task/watchdog remain authoritative." }

$collected = Collect-RemoteRun -TargetRunId $RunId
$postCheck = Invoke-RemotePowerShell -Script "`$p=@(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -Match '^(ZEON|ZEONCli)$'); [ordered]@{hostname=`$env:COMPUTERNAME;sshd=(Get-Service sshd).Status.ToString();zeon_process_count=`$p.Count} | ConvertTo-Json -Compress" | ConvertFrom-Json
$controllerResult = [ordered]@{
    schema_version = 2
    run_id = $RunId
    scenario = $Scenario
    mode = $NetworkMode
    status = [string]$collected.status.status
    verdict = [string]$collected.status.verdict
    classification = [string]$collected.status.classification
    runtime_identity = [string]$collected.status.runtime_identity
    runtime_sid = [string]$collected.status.runtime_sid
    cleanup_verified = [bool]$collected.status.cleanup_verified
    safe_to_collect = [bool]$collected.status.safe_to_collect
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
