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

function ConvertTo-RuntimeComparable {
    param($Value)
    return ($Value | ConvertTo-Json -Compress -Depth 12)
}

function Test-RuntimeEqual {
    param($Left, $Right)
    return (ConvertTo-RuntimeComparable $Left) -ceq (ConvertTo-RuntimeComparable $Right)
}

function Get-RuntimeRouteKey {
    param($Route)
    return '{0}|{1}|{2}|{3}' -f [int]$Route.InterfaceIndex, [string]$Route.DestinationPrefix, [string]$Route.NextHop, [int]$Route.RouteMetric
}

function Set-RuntimeWinInetValue {
    param([string]$UserSid, [string]$Name, $Entry)
    $mounted = Mount-RuntimeUserHive -UserSid $UserSid
    $key = [Microsoft.Win32.Registry]::Users.CreateSubKey("$UserSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings")
    try {
        if (-not [bool]$Entry.exists) {
            $key.DeleteValue($Name, $false)
        } else {
            $kind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$Entry.kind))
            $key.SetValue($Name, $Entry.value, $kind)
        }
    } finally {
        $key.Dispose()
        Dismount-RuntimeUserHive -UserSid $UserSid -MountedByCaller $mounted
    }
}

function Restore-RuntimeWinHttp {
    param($Baseline)
    if (@($Baseline.winhttp_registry_bytes).Count -gt 0) {
        $bytes = [byte[]]@($Baseline.winhttp_registry_bytes | ForEach-Object { [byte]$_ })
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -Value $bytes
    } elseif ([string]$Baseline.winhttp_show_proxy -match 'Direct access') {
        & netsh.exe winhttp reset proxy | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to restore direct WinHTTP baseline.' }
    } else {
        throw 'WinHTTP baseline cannot be restored without recorded registry bytes.'
    }
}

function Restore-RuntimeOwnedNetworkDelta {
    param($Baseline, $Owned, [string]$UserSid)
    $changes = [Collections.Generic.List[string]]::new()
    $conflicts = [Collections.Generic.List[string]]::new()
    $current = Get-RuntimeNetworkState -UserSid $UserSid

    foreach ($property in $Baseline.wininet.values.PSObject.Properties) {
        $name = $property.Name
        $baselineEntry = $property.Value
        $ownedProperty = $Owned.wininet.values.PSObject.Properties[$name]
        $currentProperty = $current.wininet.values[$name]
        $ownedEntry = if ($ownedProperty) { $ownedProperty.Value } else { $null }
        if (Test-RuntimeEqual $currentProperty $baselineEntry) { continue }
        if ($ownedEntry -and (Test-RuntimeEqual $currentProperty $ownedEntry)) {
            Set-RuntimeWinInetValue -UserSid $UserSid -Name $name -Entry $baselineEntry
            $changes.Add("wininet:$name")
        } else {
            $conflicts.Add("wininet:$name")
        }
    }

    $baselineWinHttp = [ordered]@{ text = [string]$Baseline.winhttp_show_proxy; bytes = @($Baseline.winhttp_registry_bytes) }
    $ownedWinHttp = [ordered]@{ text = [string]$Owned.winhttp_show_proxy; bytes = @($Owned.winhttp_registry_bytes) }
    $currentWinHttp = [ordered]@{ text = [string]$current.winhttp_show_proxy; bytes = @($current.winhttp_registry_bytes) }
    if (-not (Test-RuntimeEqual $currentWinHttp $baselineWinHttp)) {
        if (Test-RuntimeEqual $currentWinHttp $ownedWinHttp) {
            Restore-RuntimeWinHttp -Baseline $Baseline
            $changes.Add('winhttp')
        } else {
            $conflicts.Add('winhttp')
        }
    }

    $baselineRoutes = @{}
    foreach ($route in @($Baseline.routes_ipv4)) { $baselineRoutes[(Get-RuntimeRouteKey $route)] = $route }
    $ownedRoutes = @{}
    foreach ($route in @($Owned.routes_ipv4)) { $ownedRoutes[(Get-RuntimeRouteKey $route)] = $route }
    $currentRoutes = @{}
    foreach ($route in @($current.routes_ipv4)) { $currentRoutes[(Get-RuntimeRouteKey $route)] = $route }
    foreach ($key in @($ownedRoutes.Keys | Where-Object { -not $baselineRoutes.ContainsKey($_) })) {
        if ($currentRoutes.ContainsKey($key)) {
            $route = $currentRoutes[$key]
            Remove-NetRoute -InterfaceIndex ([int]$route.InterfaceIndex) -DestinationPrefix ([string]$route.DestinationPrefix) -NextHop ([string]$route.NextHop) -Confirm:$false -ErrorAction Stop
            $changes.Add("route-remove:$key")
        }
    }
    foreach ($key in @($baselineRoutes.Keys | Where-Object { -not $ownedRoutes.ContainsKey($_) })) {
        if ($currentRoutes.ContainsKey($key)) { continue }
        $route = $baselineRoutes[$key]
        $sameDestination = @($current.routes_ipv4 | Where-Object { [int]$_.InterfaceIndex -eq [int]$route.InterfaceIndex -and [string]$_.DestinationPrefix -ceq [string]$route.DestinationPrefix })
        if ($sameDestination.Count -gt 0) {
            $conflicts.Add("route:$([int]$route.InterfaceIndex):$([string]$route.DestinationPrefix)")
            continue
        }
        New-NetRoute -InterfaceIndex ([int]$route.InterfaceIndex) -DestinationPrefix ([string]$route.DestinationPrefix) -NextHop ([string]$route.NextHop) -RouteMetric ([int]$route.RouteMetric) -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        $changes.Add("route-add:$key")
    }

    $baselineDns = @{}
    foreach ($entry in @($Baseline.dns_ipv4)) { $baselineDns[[string][int]$entry.InterfaceIndex] = @($entry.ServerAddresses) }
    $ownedDns = @{}
    foreach ($entry in @($Owned.dns_ipv4)) { $ownedDns[[string][int]$entry.InterfaceIndex] = @($entry.ServerAddresses) }
    $currentDns = @{}
    foreach ($entry in @($current.dns_ipv4)) { $currentDns[[string][int]$entry.InterfaceIndex] = @($entry.ServerAddresses) }
    foreach ($interfaceKey in @($baselineDns.Keys | Sort-Object)) {
        $baselineAddresses = @($baselineDns[$interfaceKey])
        $ownedAddresses = @($ownedDns[$interfaceKey])
        $currentAddresses = @($currentDns[$interfaceKey])
        if (Test-RuntimeEqual $currentAddresses $baselineAddresses) { continue }
        if (Test-RuntimeEqual $currentAddresses $ownedAddresses) {
            if ($baselineAddresses.Count -eq 0) {
                Set-DnsClientServerAddress -InterfaceIndex ([int]$interfaceKey) -ResetServerAddresses -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex ([int]$interfaceKey) -ServerAddresses $baselineAddresses -ErrorAction Stop
            }
            $changes.Add("dns:$interfaceKey")
        } else {
            $conflicts.Add("dns:$interfaceKey")
        }
    }

    $after = Get-RuntimeNetworkState -UserSid $UserSid
    $comparison = Get-RuntimeStateComparison -Before $Baseline -After $after
    return [ordered]@{
        changes = @($changes)
        conflicts = @($conflicts)
        after = $after
        proxy_equal = [bool]$comparison.proxy_equal
        routes_equal = [bool]$comparison.routes_equal
        dns_equal = [bool]$comparison.dns_equal
    }
}

Assert-RuntimeSafeId -Value $ExpectedRunId -Label 'run_id'
$ActiveRunPath = Assert-RuntimePathWithin -Path $ActiveRunPath -Root (Join-Path $LabRoot 'state\runtime') -Label 'active run path'
$ArmingPath = Assert-RuntimePathWithin -Path $ArmingPath -Root (Join-Path $LabRoot 'state\runtime\arming') -Label 'arming path'
if (-not (Test-Path -LiteralPath $ActiveRunPath -PathType Leaf)) { throw 'Active run manifest is missing.' }
if (-not (Test-Path -LiteralPath $ArmingPath -PathType Leaf)) { throw 'One-time recovery arming manifest is missing.' }
$active = Get-Content -LiteralPath $ActiveRunPath -Raw | ConvertFrom-Json
$arming = Get-Content -LiteralPath $ArmingPath -Raw | ConvertFrom-Json
if ([int]$active.schema_version -ne 2 -or [int]$arming.schema_version -ne 2) { throw 'Recovery manifest schema mismatch.' }
if ([string]$active.run_id -cne $ExpectedRunId -or [string]$arming.run_id -cne $ExpectedRunId) { throw 'Recovery run_id mismatch.' }
if (-not [bool]$arming.allow_apply -or [bool]$arming.consumed) { throw 'Recovery apply is not armed.' }
if ([string]$arming.active_run_path -cne $ActiveRunPath) { throw 'Recovery arming active path mismatch.' }
if ([datetime]::Parse([string]$arming.expires_at).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) { throw 'Recovery arming manifest expired.' }
if ([string]$active.user_sid -cne [string]$arming.user_sid) { throw 'Recovery principal SID mismatch.' }
if ([string]$active.baseline_sha256 -cne [string]$arming.baseline_sha256) { throw 'Recovery baseline hash declaration mismatch.' }
if ((Get-RuntimeFileHash -Path ([string]$active.baseline_path)) -cne [string]$active.baseline_sha256) { throw 'Recovery baseline content hash mismatch.' }
if ((ConvertTo-RuntimeComparable @($active.test_process_ids)) -cne (ConvertTo-RuntimeComparable @($arming.pid_allowlist))) { throw 'Recovery PID allowlist mismatch.' }
$requiredActions = @('stop_lab_owned_processes', 'restore_owned_wininet', 'restore_owned_winhttp', 'restore_owned_routes', 'restore_owned_dns', 'start_sshd_if_stopped', 'remove_runtime_plaintext')
if ((ConvertTo-RuntimeComparable @($arming.recovery_actions)) -cne (ConvertTo-RuntimeComparable $requiredActions)) { throw 'Recovery action allowlist mismatch.' }

$runDirectory = Assert-RuntimePathWithin -Path ([string]$active.run_directory) -Root (Join-Path $LabRoot 'evidence\runs') -Label 'run directory'
$resultPath = Join-Path $runDirectory 'recovery-result.json'
$report = [ordered]@{
    schema_version = 2
    run_id = $ExpectedRunId
    user_sid = [string]$active.user_sid
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    arming_consumed = $false
    stopped_processes = @()
    skipped_processes = @()
    plaintext_removed = $false
    encrypted_fixture_removed = $false
    secret_scan_clean = $false
    wininet_restored = $false
    winhttp_restored = $false
    routes_restored = $false
    dns_restored = $false
    routes_equal = $false
    dns_equal = $false
    proxy_equal = $false
    conflicts_preserved = @()
    applied_changes = @()
    sshd_restarted = $false
    reboot_scheduled = $false
    success = $false
    error = $null
}
try {
    $arming.consumed = $true
    $arming | Add-Member -NotePropertyName consumed_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-RuntimeAtomicJson -Value $arming -Path $ArmingPath
    $report.arming_consumed = $true

    $recordedProcessIds = @($active.test_process_ids | ForEach-Object { [int]$_ })
    $owned = if ($recordedProcessIds.Count -eq 0) { [ordered]@{ stopped = @(); skipped = @() } } else { Stop-RuntimeOwnedProcesses -ProcessIds $recordedProcessIds -ApplicationRoot ([string]$active.application_root) }
    $report.stopped_processes = @($owned.stopped)
    $report.skipped_processes = @($owned.skipped)
    Start-Sleep -Seconds 3

    $scanFixturePath = if ([string]$active.fixture_plaintext_path -and (Test-Path -LiteralPath ([string]$active.fixture_plaintext_path))) { [string]$active.fixture_plaintext_path } else { $null }
    $secretScan = Protect-RuntimeEvidence -EvidenceDirectory $runDirectory -FixturePlaintextPath $scanFixturePath
    Write-RuntimeAtomicJson -Value $secretScan -Path (Join-Path $runDirectory 'secret-scan.json')
    $report.secret_scan_clean = [bool]$secretScan.clean

    if ([string]$active.fixture_plaintext_path) {
        $plainPath = Assert-RuntimePathWithin -Path ([string]$active.fixture_plaintext_path) -Root (Join-Path $env:SystemRoot 'Temp\ZEON-LAB-runtime') -Label 'runtime plaintext path'
        Remove-Item -LiteralPath $plainPath -Force -ErrorAction SilentlyContinue
        $plainDirectory = Split-Path -Parent $plainPath
        if (Test-Path -LiteralPath $plainDirectory) { Remove-Item -LiteralPath $plainDirectory -Force -Recurse -ErrorAction SilentlyContinue }
        $report.plaintext_removed = -not (Test-Path -LiteralPath $plainPath)
    } else { $report.plaintext_removed = $true }
    if ([string]$active.fixture_encrypted_path) {
        $encryptedPath = Assert-RuntimePathWithin -Path ([string]$active.fixture_encrypted_path) -Root (Join-Path $env:ProgramData 'ZEON-LAB-Secrets') -Label 'encrypted fixture path'
        Remove-Item -LiteralPath $encryptedPath -Force -ErrorAction SilentlyContinue
        $report.encrypted_fixture_removed = -not (Test-Path -LiteralPath $encryptedPath)
    } else { $report.encrypted_fixture_removed = $true }

    $baseline = Get-Content -LiteralPath ([string]$active.baseline_path) -Raw | ConvertFrom-Json
    $ownedState = if (Test-Path -LiteralPath ([string]$active.owned_state_path)) { Get-Content -LiteralPath ([string]$active.owned_state_path) -Raw | ConvertFrom-Json } else { $baseline }
    $restored = Restore-RuntimeOwnedNetworkDelta -Baseline $baseline -Owned $ownedState -UserSid ([string]$active.user_sid)
    $report.applied_changes = @($restored.changes)
    $report.conflicts_preserved = @($restored.conflicts)
    $report.proxy_equal = [bool]$restored.proxy_equal
    $report.routes_equal = [bool]$restored.routes_equal
    $report.dns_equal = [bool]$restored.dns_equal
    $report.wininet_restored = $report.proxy_equal
    $report.winhttp_restored = $report.proxy_equal
    $report.routes_restored = $report.routes_equal
    $report.dns_restored = $report.dns_equal
    Write-RuntimeAtomicJson -Value (Get-RuntimeSanitizedNetworkState -State $restored.after) -Path (Join-Path $runDirectory 'after-recovery-network.json')

    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd -and $sshd.Status -ne 'Running') {
        Start-Service -Name sshd
        $report.sshd_restarted = $true
    }
    $report.success = $report.proxy_equal -and $report.routes_equal -and $report.dns_equal -and $report.skipped_processes.Count -eq 0 -and $report.conflicts_preserved.Count -eq 0 -and $report.plaintext_removed -and $report.encrypted_fixture_removed -and $report.secret_scan_clean
} catch {
    $report.error = $_.Exception.Message
} finally {
    $report.completed_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-RuntimeAtomicJson -Value $report -Path $resultPath
    Remove-Item -LiteralPath $ArmingPath -Force -ErrorAction SilentlyContinue
}
if (-not $report.success) { throw 'Run-scoped recovery did not restore and verify the complete baseline.' }
$report
