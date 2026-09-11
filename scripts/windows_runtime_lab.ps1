[CmdletBinding()]
param(
    [ValidateSet("connect", "s02", "s06", "manual-proxy", "auto-proxy")]
    [string]$Scenario = "connect",

    [ValidateSet("system-proxy", "tun", "local-proxy")]
    [string]$NetworkMode = "system-proxy",

    [string]$ArtifactPath,

    [string]$FixturePath,

    [string]$RunId = ("HARNESS-PREFLIGHT-" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")),

    [string]$EvidenceRoot = "Z:\Zeon-Envelope\Temp\zeon-app-testing",

    [string]$LabRoot = "Z:\Zeon-Envelope\Temp\zeon-recovery-142\windows10-vm-lab",

    [ValidateRange(1, 45)][int]$ConnectTimeoutSeconds = 45,

    [ValidateRange(30, 600)][int]$BootstrapTimeoutSeconds = 240,

    [ValidateRange(15, 300)][int]$CleanupTimeoutSeconds = 90,

    [ValidateRange(0, 7200)][int]$ScenarioTimeoutSeconds = 0,

    [ValidateRange(2, 100)][int]$S02Cycles = 10,

    [ValidateRange(5, 180)][int]$ControllerTimeoutMinutes = 45,

    [switch]$Detach,

    [switch]$CollectOnly,

    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $prefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay below $resolvedRoot. Refusing: $resolvedPath"
    }
    return $resolvedPath
}

function Invoke-LabCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$OperationTimeoutSeconds = 180,
        [int]$ReadTimeoutSeconds = 190
    )
    $result = & (Join-Path $LabRoot "vm_cmd.ps1") `
        -Script $Script `
        -CredentialName Admin `
        -OperationTimeoutSeconds $OperationTimeoutSeconds `
        -ReadTimeoutSeconds $ReadTimeoutSeconds
    if ($result.StatusCode -ne 0) {
        throw "ZEON-W10-LAB command failed: $($result.StdErr)"
    }
    return $result.StdOut.Trim()
}

function Restore-And-StopCleanLab {
    & (Join-Path $LabRoot "restore-clean.ps1") | Out-Null
    & (Join-Path $LabRoot "wait-winrm.ps1") -TimeoutMinutes 30 -IntervalSeconds 10 | Out-Null
    & (Join-Path $LabRoot "stop.ps1") | Out-Null
}

function Start-WslFileServer {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Unit,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $windowsDirectory = [IO.Path]::GetFullPath($Directory)
    if ($windowsDirectory -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Unable to convert the transfer directory to a WSL mount path."
    }
    $wslDirectory = "/mnt/$($Matches[1].ToLowerInvariant())/$($Matches[2].Replace('\', '/'))"
    & wsl.exe -d Ubuntu-22.04 -u root -- systemd-run "--unit=$Unit" --collect `
        "--property=User=actes" "--property=WorkingDirectory=$wslDirectory" `
        /usr/bin/python3 -m http.server $Port --bind 127.0.0.1 --directory $wslDirectory | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to start the WSL transfer service." }
    Start-Sleep -Seconds 1
    $state = (& wsl.exe -d Ubuntu-22.04 -u root -- systemctl is-active $Unit 2>$null).Trim()
    if ($state -ne "active") { throw "WSL transfer service did not become active: $state" }
}

function Stop-WslFileServer {
    param([Parameter(Mandatory = $true)][string]$Unit)
    & wsl.exe -d Ubuntu-22.04 -u root -- systemctl stop $Unit 2>$null | Out-Null
}

if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') {
    throw "RunId must contain 3-80 safe filename characters."
}
if ($ScenarioTimeoutSeconds -eq 0) {
    $ScenarioTimeoutSeconds = switch ($Scenario) {
        "s02" { 3600 }
        "s06" { 300 }
        "connect" { 300 }
        default { 600 }
    }
}
if ($ScenarioTimeoutSeconds -lt 60) {
    throw "ScenarioTimeoutSeconds must be 0 (scenario default) or between 60 and 7200."
}

$requiredLabFiles = @("start.ps1", "stop.ps1", "restore-clean.ps1", "wait-winrm.ps1", "vm_cmd.ps1", "fetch-guest-file.ps1", "start-wsl.sh")
$LabRoot = Assert-PathWithin -Path $LabRoot -Root "Z:\Zeon-Envelope\Temp" -Label "LabRoot"
foreach ($name in $requiredLabFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $LabRoot $name) -PathType Leaf)) {
        throw "Required ZEON-W10-LAB controller is missing: $name"
    }
}
$qemuLaunch = Get-Content -LiteralPath (Join-Path $LabRoot "start-wsl.sh") -Raw
if ($qemuLaunch -notmatch '(?i)(-accel\s+tcg|accel=tcg)' -or $qemuLaunch -match '(?i)whpx') {
    throw "ZEON-W10-LAB must use TCG and must not contain WHPX."
}

if ($ValidateOnly) {
    [pscustomobject]@{
        Valid = $true
        Machine = "ZEON-W10-LAB"
        Scenarios = @("connect", "s02", "s06", "manual-proxy", "auto-proxy")
        Modes = @("system-proxy", "tun", "local-proxy")
        ConnectReadinessMaximumSeconds = 45
        ScenarioTimeoutSeconds = $ScenarioTimeoutSeconds
        S06ObservationSeconds = 150
        UsesUiAutomation = $false
    }
    return
}

$EvidenceRoot = Assert-PathWithin -Path $EvidenceRoot -Root "Z:\Zeon-Envelope\Temp" -Label "EvidenceRoot"
$hostRunDirectory = Assert-PathWithin -Path (Join-Path $EvidenceRoot $RunId) -Root $EvidenceRoot -Label "Run evidence"
if ((Test-Path -LiteralPath $hostRunDirectory) -and -not $CollectOnly) {
    throw "Run evidence directory already exists: $hostRunDirectory"
}

$guestRunRoot = "C:\ZeonLab\runtime\runs\$RunId"
$guestEvidence = "$guestRunRoot\evidence"
$guestZip = "$guestRunRoot\evidence.zip"
$taskName = "ZEON Runtime $RunId"
$finalizeLab = -not $Detach
$labTouched = $CollectOnly
$transferService = $null
$transferStage = $null

try {
    if (-not $CollectOnly) {
        if (-not $ArtifactPath -or -not $FixturePath) {
            throw "ArtifactPath and FixturePath are required unless CollectOnly is used."
        }
        $ArtifactPath = Assert-PathWithin -Path $ArtifactPath -Root "Z:\Zeon-Envelope\Projects\zeon-app\out\installers\win" -Label "ArtifactPath"
        $FixturePath = Assert-PathWithin -Path $FixturePath -Root "Z:\Zeon-Envelope\Temp" -Label "FixturePath"
        foreach ($file in @($ArtifactPath, $FixturePath)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required input file was not found: $file" }
        }
        $manifestPath = $ArtifactPath + ".manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Runtime build manifest was not found: $manifestPath" }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $artifactHash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash
        if ($manifest.schema -ne "zeon.windows-runtime-build.v1" -or
            $manifest.build_type -ne "windows-runtime-validation" -or
            $manifest.artifact_sha256 -ne $artifactHash) {
            throw "Runtime artifact provenance validation failed."
        }
        $fixtureHash = (Get-FileHash -LiteralPath $FixturePath -Algorithm SHA256).Hash

        $labTouched = $true
        & (Join-Path $LabRoot "restore-clean.ps1") | Out-Null
        & (Join-Path $LabRoot "wait-winrm.ps1") -TimeoutMinutes 30 -IntervalSeconds 10 | Out-Null
        $machine = Invoke-LabCommand -Script '$env:COMPUTERNAME'
        if ($machine -ne "ZEON-W10-LAB") { throw "Unexpected lab machine: $machine" }

        $transferToken = [guid]::NewGuid().ToString("N")
        $transferStage = Assert-PathWithin `
            -Path (Join-Path "Z:\Zeon-Envelope\Temp\zeon-app-runtime-transfer" $transferToken) `
            -Root "Z:\Zeon-Envelope\Temp" `
            -Label "Transfer staging"
        New-Item -ItemType Directory -Path $transferStage -Force | Out-Null
        New-Item -ItemType HardLink -Path (Join-Path $transferStage "artifact.zip") -Target $ArtifactPath | Out-Null
        New-Item -ItemType HardLink -Path (Join-Path $transferStage "fixture.txt") -Target $FixturePath | Out-Null
        $fileServerPort = Get-Random -Minimum 40000 -Maximum 54000
        $transferService = "zeon-runtime-transfer-$($transferToken.Substring(0, 12)).service"
        Start-WslFileServer -Directory $transferStage -Unit $transferService -Port $fileServerPort

        $stageScript = @"
`$ErrorActionPreference = 'Stop'
`$runRoot = '$guestRunRoot'
if (Test-Path -LiteralPath `$runRoot) { throw 'Guest run directory already exists.' }
New-Item -ItemType Directory -Path `$runRoot -Force | Out-Null
`$artifact = Join-Path `$runRoot 'artifact.zip'
`$fixture = Join-Path `$runRoot 'profile.fixture'
Invoke-WebRequest -UseBasicParsing -Uri 'http://10.0.2.2:$fileServerPort/artifact.zip' -OutFile `$artifact
Invoke-WebRequest -UseBasicParsing -Uri 'http://10.0.2.2:$fileServerPort/fixture.txt' -OutFile `$fixture
if ((Get-FileHash -LiteralPath `$artifact -Algorithm SHA256).Hash -ne '$artifactHash') { throw 'Artifact transfer hash mismatch.' }
if ((Get-FileHash -LiteralPath `$fixture -Algorithm SHA256).Hash -ne '$fixtureHash') { throw 'Fixture transfer hash mismatch.' }
`$appRoot = Join-Path `$runRoot 'app'
Expand-Archive -LiteralPath `$artifact -DestinationPath `$appRoot
if (-not (Test-Path -LiteralPath (Join-Path `$appRoot 'ZEON.exe'))) { throw 'Runtime executable missing after extraction.' }
New-Item -ItemType Directory -Path '$guestEvidence' -Force | Out-Null
        "@
        Invoke-LabCommand -Script $stageScript -OperationTimeoutSeconds 300 -ReadTimeoutSeconds 320 | Out-Null
        Stop-WslFileServer -Unit $transferService
        $transferService = $null
        Remove-Item -LiteralPath $transferStage -Recurse -Force
        $transferStage = $null

        $launcherScript = @"
`$ErrorActionPreference = 'Stop'
`$runRoot = '$guestRunRoot'
`$appRoot = Join-Path `$runRoot 'app'
`$evidence = '$guestEvidence'
New-Item -ItemType Directory -Path `$evidence -Force | Out-Null
foreach (`$name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy')) {
    Remove-Item ("Env:" + `$name) -ErrorAction SilentlyContinue
}
`$arguments = @(
    '--scenario','$Scenario',
    '--mode','$NetworkMode',
    '--evidence-dir',`$evidence,
    '--profile-file',(Join-Path `$runRoot 'profile.fixture'),
    '--run-id','$RunId',
    '--connect-timeout-seconds','$ConnectTimeoutSeconds',
    '--bootstrap-timeout-seconds','$BootstrapTimeoutSeconds',
    '--cleanup-timeout-seconds','$CleanupTimeoutSeconds',
    '--scenario-timeout-seconds','$ScenarioTimeoutSeconds',
    '--s02-cycles','$S02Cycles'
)
`$process = Start-Process -FilePath (Join-Path `$appRoot 'ZEON.exe') -WorkingDirectory `$appRoot -ArgumentList `$arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path `$evidence 'stdout.log') -RedirectStandardError (Join-Path `$evidence 'stderr.log')
`$process.ExitCode.ToString() | Set-Content -LiteralPath (Join-Path `$evidence 'process-exit-code.txt') -Encoding ascii
`$portable = Join-Path `$appRoot 'zeon_portable_data'
`$logPaths = @('app.log','box.log','stderr.log','stderr3.log','stderr4.log','data\box.log','data\stderr.log','data\stderr3.log','data\stderr4.log')
`$logEvidence = Join-Path `$evidence 'logs'
New-Item -ItemType Directory -Path `$logEvidence -Force | Out-Null
foreach (`$relative in `$logPaths) {
    `$source = Join-Path `$portable `$relative
    if (Test-Path -LiteralPath `$source -PathType Leaf) {
        `$destination = (`$relative -replace '[\\/]', '-')
        Copy-Item -LiteralPath `$source -Destination (Join-Path `$logEvidence `$destination) -Force
    }
}
"@
        $launcherBytes = [Text.Encoding]::UTF8.GetBytes($launcherScript)
        $launcherBase64 = [Convert]::ToBase64String($launcherBytes)
        $registerScript = @"
`$ErrorActionPreference = 'Stop'
`$launcher = '$guestRunRoot\launch-runtime.ps1'
[IO.File]::WriteAllBytes(`$launcher, [Convert]::FromBase64String('$launcherBase64'))
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + `$launcher + '"') -WorkingDirectory '$guestRunRoot'
`$principal = New-ScheduledTaskPrincipal -UserId (`$env:COMPUTERNAME + '\zeonadmin') -LogonType Interactive -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $($ScenarioTimeoutSeconds + $CleanupTimeoutSeconds + $BootstrapTimeoutSeconds + 300)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName '$taskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
Start-ScheduledTask -TaskName '$taskName'
[pscustomobject]@{ Task='$taskName'; RunId='$RunId'; Evidence='$guestEvidence'; StartedUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
"@
        Invoke-LabCommand -Script $registerScript | Out-Null
        Write-Host "Runtime task started independently in ZEON-W10-LAB: $taskName"
        if ($Detach) {
            [pscustomobject]@{
                Status = "DETACHED"
                RunId = $RunId
                Task = $taskName
                CollectCommand = ".\scripts\windows_runtime_lab.ps1 -CollectOnly -RunId '$RunId'"
            }
            return
        }
    }

    $deadline = [DateTime]::UtcNow.AddMinutes($ControllerTimeoutMinutes)
    do {
        $statusJson = Invoke-LabCommand -Script @"
`$result = '$guestEvidence\result.json'
`$task = Get-ScheduledTask -TaskName '$taskName' -ErrorAction SilentlyContinue
[pscustomobject]@{ ResultExists=(Test-Path -LiteralPath `$result); TaskState=`$(if (`$task) { `$task.State.ToString() } else { 'Missing' }) } | ConvertTo-Json -Compress
"@
        $status = $statusJson | ConvertFrom-Json
        if ($status.ResultExists) { break }
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $status.ResultExists) { throw "Runtime result did not appear within $ControllerTimeoutMinutes minutes." }

    $archiveScript = @"
`$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath '$guestZip') { Remove-Item -LiteralPath '$guestZip' -Force }
Compress-Archive -Path '$guestEvidence\*' -DestinationPath '$guestZip' -CompressionLevel Optimal
(Get-FileHash -LiteralPath '$guestZip' -Algorithm SHA256).Hash
"@
    $guestEvidenceHash = Invoke-LabCommand -Script $archiveScript -OperationTimeoutSeconds 300 -ReadTimeoutSeconds 320
    New-Item -ItemType Directory -Path $hostRunDirectory -Force | Out-Null
    $hostZip = Join-Path $hostRunDirectory "evidence.zip"
    & (Join-Path $LabRoot "fetch-guest-file.ps1") -GuestPath $guestZip -HostPath $hostZip -CredentialName Admin | Out-Null
    $downloadedHash = (Get-FileHash -LiteralPath $hostZip -Algorithm SHA256).Hash
    if ($downloadedHash -ne $guestEvidenceHash) { throw "Evidence transfer hash mismatch." }
    $expanded = Join-Path $hostRunDirectory "evidence"
    Expand-Archive -LiteralPath $hostZip -DestinationPath $expanded
    $resultPath = Join-Path $expanded "result.json"
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Downloaded evidence has no result.json." }
    $runtimeResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Status = $runtimeResult.verdict
        Reason = $runtimeResult.reason
        RunId = $RunId
        Result = $resultPath
        Events = (Join-Path $expanded "events.jsonl")
        Archive = $hostZip
        ArchiveSHA256 = $downloadedHash
    }
}
finally {
    if ($transferService) {
        Stop-WslFileServer -Unit $transferService
    }
    if ($transferStage -and (Test-Path -LiteralPath $transferStage)) {
        $transferStage = Assert-PathWithin -Path $transferStage -Root "Z:\Zeon-Envelope\Temp" -Label "Transfer cleanup"
        Remove-Item -LiteralPath $transferStage -Recurse -Force
    }
    if ($finalizeLab -and $labTouched -and -not $ValidateOnly) {
        Restore-And-StopCleanLab
    }
}
