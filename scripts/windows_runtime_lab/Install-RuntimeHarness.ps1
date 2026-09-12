[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [string]$LabRoot = 'C:\ZEON-LAB'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Set-RuntimeUserRights {
    param([Parameter(Mandatory = $true)][string]$Sid)
    $temporaryRoot = Join-Path $env:TEMP ("zeon-runtime-rights-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $configuration = Join-Path $temporaryRoot 'rights.inf'
    $database = Join-Path $temporaryRoot 'rights.sdb'
    try {
        & secedit.exe /export /cfg $configuration /areas USER_RIGHTS /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to export local user-right assignments.' }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]][IO.File]::ReadAllLines($configuration, [Text.Encoding]::Unicode))
        foreach ($right in @('SeBatchLogonRight', 'SeDenyInteractiveLogonRight', 'SeDenyRemoteInteractiveLogonRight')) {
            $index = -1
            for ($position = 0; $position -lt $lines.Count; $position++) {
                if ($lines[$position] -match ("^{0}\s*=" -f [regex]::Escape($right))) { $index = $position; break }
            }
            $sidToken = "*$Sid"
            if ($index -ge 0) {
                $parts = $lines[$index].Split('=', 2)
                $existing = @($parts[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($existing -notcontains $sidToken) { $existing += $sidToken }
                $lines[$index] = "$right = $($existing -join ',')"
            } else {
                $privilegeHeader = -1
                for ($position = 0; $position -lt $lines.Count; $position++) {
                    if ($lines[$position] -ceq '[Privilege Rights]') { $privilegeHeader = $position; break }
                }
                if ($privilegeHeader -lt 0) { throw 'Exported security policy has no Privilege Rights section.' }
                $insertAt = $lines.Count
                for ($position = $privilegeHeader + 1; $position -lt $lines.Count; $position++) {
                    if ($lines[$position] -match '^\[[^]]+\]$') { $insertAt = $position; break }
                }
                $lines.Insert($insertAt, "$right = $sidToken")
            }
        }
        [IO.File]::WriteAllLines($configuration, $lines, [Text.Encoding]::Unicode)
        & secedit.exe /configure /db $database /cfg $configuration /areas USER_RIGHTS /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to apply runtime user-right assignments.' }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Force -Recurse }
    }
}

$manifestPath = Join-Path $SourceDirectory 'deployment-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Runtime deployment manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1) { throw 'Unsupported runtime deployment manifest.' }

$destination = Join-Path $LabRoot 'scripts\runtime'
$stateRoot = Join-Path $LabRoot 'state\runtime'
$secretRoot = Join-Path $env:ProgramData 'ZEON-LAB-Secrets'
$runtimeEvidenceRoot = Join-Path $LabRoot 'evidence\runs'
$runtimeTempRoot = Join-Path $LabRoot 'temp\runtime'
if (Test-Path -LiteralPath (Join-Path $stateRoot 'active-run.json')) { throw 'Cannot deploy the runtime harness while a run is active.' }
if (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'queue') -Filter '*.request.json' -File -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Cannot deploy the runtime harness while a run is queued.' }
$testUserName = 'ZEONRuntime'
$testUser = Get-LocalUser -Name $testUserName -ErrorAction SilentlyContinue
$existingRunnerTask = Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation' -ErrorAction SilentlyContinue
$newPrincipal = $null -eq $testUser
$passwordBytes = $null
$passwordText = $null
$securePassword = $null
if ($testUser) {
    if (-not $existingRunnerTask -or $existingRunnerTask.Principal.UserId -notin @($testUserName, "$env:COMPUTERNAME\$testUserName") -or $existingRunnerTask.Principal.LogonType -ne 'Password') {
        throw 'Existing runtime principal has no reusable Password scheduled task; refuse a password reset that would invalidate CurrentUser DPAPI.'
    }
    Set-LocalUser -Name $testUserName -PasswordNeverExpires $true -UserMayChangePassword $false
} else {
    $passwordBytes = New-Object byte[] 36
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($passwordBytes) } finally { $random.Dispose() }
    $passwordText = ([Convert]::ToBase64String($passwordBytes) + 'aA1!')
    $securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
    $testUser = New-LocalUser -Name $testUserName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Description 'ZEON runtime test principal'
}
if (-not (Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Where-Object { $_.SID -eq $testUser.SID })) {
    Add-LocalGroupMember -Group 'Administrators' -Member $testUserName
}
$testUser = Get-LocalUser -Name $testUserName
$testUserSid = $testUser.SID.Value
Set-RuntimeUserRights -Sid $testUserSid

foreach ($path in @($destination, $stateRoot, (Join-Path $stateRoot 'queue'), (Join-Path $stateRoot 'archive'), (Join-Path $stateRoot 'arming'), (Join-Path $stateRoot 'baselines'), $runtimeTempRoot, (Join-Path $LabRoot 'temp\exports'), $runtimeEvidenceRoot, $secretRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$requiredFiles = @(
    'RuntimeLab.Common.ps1',
    'Protect-RuntimeFixture.ps1',
    'Queue-RuntimeRun.ps1',
    'Invoke-RuntimeRunner.ps1',
    'Invoke-RuntimeWatchdog.ps1',
    'Invoke-RuntimeRecovery.ps1',
    'Invoke-RuntimeManualRecovery.ps1',
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
Set-RuntimeRestrictedAcl -Path $destination -AdditionalReadExecuteSids @($testUserSid)
Set-RuntimeRestrictedAcl -Path $stateRoot -AdditionalFullControlSids @($testUserSid)
Set-RuntimeRestrictedAcl -Path $runtimeTempRoot -AdditionalFullControlSids @($testUserSid)
Set-RuntimeRestrictedAcl -Path $runtimeEvidenceRoot -AdditionalFullControlSids @($testUserSid)
Set-RuntimeRestrictedAcl -Path $secretRoot -AdditionalFullControlSids @($testUserSid)
Set-RuntimeRestrictedAcl -Path (Join-Path $LabRoot 'artifacts') -AdditionalReadExecuteSids @($testUserSid)

$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$runnerArgument = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1'
$runnerAction = New-ScheduledTaskAction -Execute $powerShell -Argument $runnerArgument
$runnerSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
$qualifiedTestUser = "$env:COMPUTERNAME\$testUserName"
if ($newPrincipal) {
    try {
        Register-ScheduledTask -TaskName 'ZEON-LAB Runtime Validation' -TaskPath '\ZEON-LAB\' -Action $runnerAction -User $qualifiedTestUser -Password $passwordText -RunLevel Highest -Settings $runnerSettings -Description 'Detached ZEON product runtime validation under a permanent denied-interactive profile. Requests are immutable JSON.' -Force | Out-Null
    } finally {
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        $passwordText = $null
        $securePassword.Dispose()
    }
} else {
    $existingActions = @($existingRunnerTask.Actions)
    if ($existingActions.Count -ne 1 -or
        -not ([string]$existingActions[0].Execute).Equals($powerShell, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$existingActions[0].Arguments -cne $runnerArgument) {
        throw 'Existing Password task action drifted; refuse credential replacement because it would invalidate CurrentUser DPAPI.'
    }
}

$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$watchdogAction = New-ScheduledTaskAction -Execute $powerShell -Argument '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeWatchdog.ps1'
$watchdogTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1))
)
$watchdogSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'ZEON-LAB Runtime Watchdog' -TaskPath '\ZEON-LAB\' -Action $watchdogAction -Trigger $watchdogTriggers -Principal $watchdogPrincipal -Settings $watchdogSettings -Description 'SYSTEM watchdog; apply requires a validated one-time run-scoped manifest. Automatic reboot is forbidden.' -Force | Out-Null

Start-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation'
$profileDeadline = (Get-Date).AddSeconds(45)
do {
    Start-Sleep -Milliseconds 500
    $taskState = (Get-ScheduledTask -TaskPath '\ZEON-LAB\' -TaskName 'ZEON-LAB Runtime Validation').State
} while ($taskState -eq 'Running' -and (Get-Date) -lt $profileDeadline)
if ($taskState -eq 'Running') { throw 'Runtime principal profile initialization did not finish.' }
$profilePath = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$testUserSid" -ErrorAction Stop).ProfileImagePath)
if (-not (Test-Path -LiteralPath (Join-Path $profilePath 'NTUSER.DAT') -PathType Leaf)) { throw 'Runtime principal profile was not created.' }
$runtimeUserDataPath = Join-Path $profilePath 'AppData\Roaming\zeon'
if (Test-Path -LiteralPath $runtimeUserDataPath) { Remove-Item -LiteralPath $runtimeUserDataPath -Force -Recurse }

$installed = [ordered]@{
    schema_version = 2
    installed_at = (Get-Date).ToUniversalTime().ToString('o')
    hostname = $env:COMPUTERNAME
    source_controller_sha = [string]$manifest.controller_sha
    script_hashes = $verified
    task = [ordered]@{
        path = '\ZEON-LAB\'
        name = 'ZEON-LAB Runtime Validation'
        principal = $qualifiedTestUser
        sid = $testUserSid
        logon_type = 'Password'
        interactive_logon = 'denied'
        remote_interactive_logon = 'denied'
        local_administrator = $true
        administrator_reason = 'Windows TUN and route ownership require an elevated token; interactive and RDP logon remain denied.'
        password_lifecycle = 'generated only at first provisioning; retained only by Task Scheduler and never reset during deployment'
        product_state = 'dedicated roaming ZEON state is reset at run boundaries'
        action = 'C:\ZEON-LAB\scripts\runtime\Invoke-RuntimeRunner.ps1'
    }
    watchdog = [ordered]@{
        name = 'ZEON-LAB Runtime Watchdog'
        principal = 'SYSTEM'
        default_mode = 'dry_run'
        apply_gate = 'one-time run-scoped arming manifest'
        automatic_reboot = $false
    }
}
Write-RuntimeAtomicJson -Value $installed -Path (Join-Path $stateRoot 'deployment.json')
$installed | ConvertTo-Json -Depth 10
