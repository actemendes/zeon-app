Set-StrictMode -Version Latest

function Write-RuntimeAtomicJson {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Assert-RuntimeSafeId {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$Label = 'identifier')
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$') {
        throw "$Label must contain 3-80 safe filename characters."
    }
}

function Get-RuntimeFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-RuntimeEvent {
    param(
        [Parameter(Mandatory = $true)][string]$EventsPath,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Details = @{}
    )
    $payload = [ordered]@{
        utc = (Get-Date).ToUniversalTime().ToString('o')
        run_id = $RunId
        event = $Event
    }
    foreach ($entry in $Details.GetEnumerator()) { $payload[$entry.Key] = $entry.Value }
    Add-Content -LiteralPath $EventsPath -Value ($payload | ConvertTo-Json -Compress -Depth 10) -Encoding utf8
}

function Get-RuntimeRegistrySnapshot {
    param([Parameter(Mandatory = $true)][string]$UserSid)
    $path = "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$UserSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings")
    $values = [ordered]@{}
    try {
        foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL', 'AutoDetect')) {
            if ($key -and ($key.GetValueNames() -contains $name)) {
                $raw = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $values[$name] = [ordered]@{
                    exists = $true
                    kind = $key.GetValueKind($name).ToString()
                    value = $raw
                }
            } else {
                $values[$name] = [ordered]@{ exists = $false; kind = $null; value = $null }
            }
        }
    } finally {
        if ($key) { $key.Dispose() }
    }
    return [ordered]@{ path = $path; values = $values }
}

function Get-RuntimeNetworkState {
    param([string]$UserSid = 'S-1-5-18')
    $winHttpKey = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -ErrorAction SilentlyContinue
    return [ordered]@{
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        user_sid = $UserSid
        wininet = Get-RuntimeRegistrySnapshot -UserSid $UserSid
        winhttp_show_proxy = (& netsh.exe winhttp show proxy 2>&1 | Out-String).Trim()
        winhttp_registry_bytes = @($winHttpKey.WinHttpSettings)
        routes_ipv4 = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric |
            Select-Object InterfaceIndex, DestinationPrefix, NextHop, RouteMetric, Protocol, PolicyStore)
        dns_ipv4 = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Sort-Object InterfaceIndex |
            Select-Object InterfaceIndex, InterfaceAlias, ServerAddresses)
        listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Sort-Object LocalAddress, LocalPort, OwningProcess |
            Select-Object LocalAddress, LocalPort, OwningProcess)
    }
}

function Get-RuntimeStateComparison {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )
    $beforeProxy = [ordered]@{
        wininet = $Before.wininet
        winhttp_show_proxy = [string]$Before.winhttp_show_proxy
        winhttp_registry_bytes = @($Before.winhttp_registry_bytes)
    } | ConvertTo-Json -Compress -Depth 12
    $afterProxy = [ordered]@{
        wininet = $After.wininet
        winhttp_show_proxy = [string]$After.winhttp_show_proxy
        winhttp_registry_bytes = @($After.winhttp_registry_bytes)
    } | ConvertTo-Json -Compress -Depth 12
    $beforeRoutes = @($Before.routes_ipv4) | ConvertTo-Json -Compress -Depth 8
    $afterRoutes = @($After.routes_ipv4) | ConvertTo-Json -Compress -Depth 8
    $beforeDns = @($Before.dns_ipv4) | ConvertTo-Json -Compress -Depth 8
    $afterDns = @($After.dns_ipv4) | ConvertTo-Json -Compress -Depth 8
    return [ordered]@{
        proxy_equal = $beforeProxy -ceq $afterProxy
        routes_equal = $beforeRoutes -ceq $afterRoutes
        dns_equal = $beforeDns -ceq $afterDns
    }
}

function Restore-RuntimeProxyBaseline {
    param([Parameter(Mandatory = $true)]$Baseline)
    $sid = [string]$Baseline.user_sid
    if ($sid -ne 'S-1-5-18') { throw 'Runtime recovery is limited to the SYSTEM profile SID.' }
    $subKey = "$sid\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $key = [Microsoft.Win32.Registry]::Users.CreateSubKey($subKey)
    try {
        foreach ($property in $Baseline.wininet.values.PSObject.Properties) {
            $name = $property.Name
            $entry = $property.Value
            if (-not [bool]$entry.exists) {
                $key.DeleteValue($name, $false)
                continue
            }
            $kind = [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$entry.kind))
            $key.SetValue($name, $entry.value, $kind)
        }
    } finally {
        $key.Dispose()
    }
    if (@($Baseline.winhttp_registry_bytes).Count -gt 0) {
        $bytes = [byte[]]@($Baseline.winhttp_registry_bytes | ForEach-Object { [byte]$_ })
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -Value $bytes
    } elseif ([string]$Baseline.winhttp_show_proxy -match 'Direct access') {
        & netsh.exe winhttp reset proxy | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to restore the direct WinHTTP baseline.' }
    } else {
        throw 'WinHTTP baseline cannot be restored without recorded registry bytes.'
    }
}

function Get-RuntimeOwnedProcessIds {
    param([Parameter(Mandatory = $true)][string]$ApplicationRoot)
    $root = [IO.Path]::GetFullPath($ApplicationRoot).TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $path = [string]$_.ExecutablePath
        $path -and [IO.Path]::GetFullPath($path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -ExpandProperty ProcessId)
}

function Stop-RuntimeOwnedProcesses {
    param(
        [Parameter(Mandatory = $true)][int[]]$ProcessIds,
        [Parameter(Mandatory = $true)][string]$ApplicationRoot
    )
    $root = [IO.Path]::GetFullPath($ApplicationRoot).TrimEnd('\') + '\'
    $stopped = @()
    $skipped = @()
    foreach ($processId in @($ProcessIds | Sort-Object -Unique -Descending)) {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $processId) -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        $path = [string]$process.ExecutablePath
        if ($path -and [IO.Path]::GetFullPath($path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            $stopped += [int]$processId
        } else {
            $skipped += [int]$processId
        }
    }
    return [ordered]@{ stopped = $stopped; skipped = $skipped }
}

function Set-RuntimeRestrictedAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    $acl = if ($item.PSIsContainer) {
        New-Object System.Security.AccessControl.DirectorySecurity
    } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($item.PSIsContainer) {
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        [System.Security.AccessControl.InheritanceFlags]::None
    }
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $full, $inheritance, [System.Security.AccessControl.PropagationFlags]::None, $allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-RuntimeEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [string]$FixturePlaintextPath
    )
    $fixtureText = $null
    if ($FixturePlaintextPath -and (Test-Path -LiteralPath $FixturePlaintextPath)) {
        $fixtureText = [IO.File]::ReadAllText($FixturePlaintextPath).Trim()
    }
    $redactedFiles = @()
    $detectedBefore = 0
    $remainingAfter = 0
    $profilePattern = '(?i)\b(?:vless|vmess|trojan|ss|hysteria2?|tuic):\/\/[^\s"''<>]+'
    foreach ($file in @(Get-ChildItem -LiteralPath $EvidenceDirectory -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.jsonl', '.log', '.txt') })) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $changed = $false
        if ($fixtureText -and $text.Contains($fixtureText)) {
            $detectedBefore++
            $text = $text.Replace($fixtureText, '[REDACTED_FIXTURE]')
            $changed = $true
        }
        if ([regex]::IsMatch($text, $profilePattern)) {
            $detectedBefore++
            $text = [regex]::Replace($text, $profilePattern, '[REDACTED_PROFILE_URI]')
            $changed = $true
        }
        if ($changed) {
            [IO.File]::WriteAllText($file.FullName, $text, [Text.UTF8Encoding]::new($false))
            $redactedFiles += $file.FullName.Substring($EvidenceDirectory.Length).TrimStart('\')
        }
        $verifyText = [IO.File]::ReadAllText($file.FullName)
        if (($fixtureText -and $verifyText.Contains($fixtureText)) -or [regex]::IsMatch($verifyText, $profilePattern)) {
            $remainingAfter++
        }
    }
    return [ordered]@{
        schema_version = 1
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
        files_scanned = @(Get-ChildItem -LiteralPath $EvidenceDirectory -File -Recurse -ErrorAction SilentlyContinue).Count
        detections_before_redaction = $detectedBefore
        redacted_files = $redactedFiles
        remaining_detections = $remainingAfter
        clean = $remainingAfter -eq 0
    }
}
