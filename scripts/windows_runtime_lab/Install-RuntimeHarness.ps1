[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$manifestPath = Join-Path $SourceDirectory 'deployment-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Runtime deployment manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1) { throw 'Unsupported runtime deployment manifest.' }

$destination = Join-Path $LabRoot 'scripts\runtime'
$stateRoot = Join-Path $LabRoot 'state\runtime'
$secretRoot = Join-Path $env:ProgramData 'ZEON-LAB-Secrets'
foreach ($path in @($destination, $stateRoot, (Join-Path $stateRoot 'queue'), (Join-Path $stateRoot 'archive'), (Join-Path $stateRoot 'arming'), (Join-Path $LabRoot 'temp\runtime'), (Join-Path $LabRoot 'temp\exports'), $secretRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$requiredFiles = @(
    'RuntimeLab.Common.ps1',
    'Protect-RuntimeFixture.ps1',
    'Queue-RuntimeRun.ps1',
    'Invoke-RuntimeRunner.ps1',
    'Invoke-RuntimeWatchdog.ps1',
    'Invoke-RuntimeRecovery.ps1',
    'Test-RuntimeHarness.ps1'
)
$verified = @()
foreach ($fileName in $requiredFiles) {
    $source = Join-Path $SourceDirectory $fileName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Runtime harness file is missing: $fileName" }
    $entry = @($manifest.files | Where-Object { [string]$_.name -ceq $fileName })
    if ($entry.Count -ne 1) { throw "Runtime deployment hash is missing or ambiguous: $fileName" }
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne ([string]$entry[0].sha256).ToLowerInvariant()) { throw "Runtime deployment hash mismatch: $fileName" }
    $verified += [ordered]@{ name = $fileName; sha256 = $actual }
}

foreach ($entry in $verified) {
    Copy-Item -LiteralPath (Join-Path $SourceDirectory $entry.name) -Destination (Join-Path $destination $entry.name) -Force
}
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $destination 'deployment-manifest.json') -Force

. (Join-Path $destination 'RuntimeLab.Common.ps1')
Set-RuntimeRestrictedAcl -Path $destination
Set-RuntimeRestrictedAcl -Path $stateRoot
Set-RuntimeRestrictedAcl -Path $secretRoot

$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$runnerAction = New-ScheduledTaskAction -Execute $powerShell -Argument '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1'
$runnerSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'ZEON-LAB Runtime Validation' -TaskPath '\ZEON-LAB\' -Action $runnerAction -Principal $principal -Settings $runnerSettings -Description 'Detached ZEON product runtime validation. Requests are immutable JSON; no credentials are stored in the task.' -Force | Out-Null

$watchdogAction = New-ScheduledTaskAction -Execute $powerShell -Argument '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeWatchdog.ps1'
$watchdogTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1))
)
$watchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'ZEON-LAB Runtime Watchdog' -TaskPath '\ZEON-LAB\' -Action $watchdogAction -Trigger $watchdogTriggers -Principal $principal -Settings $watchdogSettings -Description 'Dry-run unless a one-time run-scoped arming manifest is valid. Automatic reboot is forbidden.' -Force | Out-Null

$installed = [ordered]@{
    schema_version = 1
    installed_at = (Get-Date).ToUniversalTime().ToString('o')
    hostname = $env:COMPUTERNAME
    source_controller_sha = [string]$manifest.controller_sha
    script_hashes = $verified
    task = [ordered]@{
        path = '\ZEON-LAB\'
        name = 'ZEON-LAB Runtime Validation'
        principal = 'SYSTEM'
        action = 'C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1'
    }
    watchdog = [ordered]@{
        name = 'ZEON-LAB Runtime Watchdog'
        default_mode = 'dry_run'
        apply_gate = 'one-time run-scoped arming manifest'
        automatic_reboot = $false
    }
}
Write-RuntimeAtomicJson -Value $installed -Path (Join-Path $stateRoot 'deployment.json')
$installed | ConvertTo-Json -Depth 10

