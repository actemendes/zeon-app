param(
    [string]$ExePath,
    [string]$OutputDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'

function Find-ZeonExe {
    param([string]$Path)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "ZEON.exe not found: $Path" }
        return (Resolve-Path -LiteralPath $Path).Path
    }
    foreach ($process in @(Get-Process -Name ZEON -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) { return $process.Path }
        } catch { }
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\ZEON\ZEON.exe'),
        (Join-Path $env:LOCALAPPDATA 'ZEON\ZEON.exe'),
        (Join-Path $env:ProgramFiles 'ZEON\ZEON.exe')
    )
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'ZEON\ZEON.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    foreach ($key in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($entry in @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -notmatch '^ZEON(?:\s|$)' -or -not $entry.InstallLocation) { continue }
            $candidate = Join-Path ([string]$entry.InstallLocation) 'ZEON.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
    }
    throw 'Cannot locate ZEON.exe. Rerun with -ExePath "C:\path\to\ZEON.exe".'
}

function Get-ProxySummary {
    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $server = [string]$settings.ProxyServer
    $serverSummary = if (-not $server) {
        'none'
    } elseif ($server -match '(?i)(127\.0\.0\.1|localhost|\[::1\])') {
        $server
    } else {
        'non-loopback proxy configured (address redacted)'
    }
    $winHttpRaw = (& netsh winhttp show proxy 2>&1 | Out-String)
    $winHttpSummary = if ($winHttpRaw -match '(?i)(127\.0\.0\.1|localhost|\[::1\])') {
        'loopback proxy configured'
    } elseif ($winHttpRaw -match '(?i)(Direct access|прямой доступ)') {
        'direct access'
    } else {
        'custom or unknown (address redacted)'
    }
    return @(
        "wininet_proxy_enabled=$([int]$settings.ProxyEnable)",
        "wininet_proxy_server=$serverSummary",
        "wininet_pac_enabled=$([bool]$settings.AutoConfigURL)",
        "wininet_autodetect=$([bool]$settings.AutoDetect)",
        "winhttp_proxy=$winHttpSummary"
    )
}

function Get-NetworkSummary {
    $result = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')) {
            $result.Add("adapter_up=$($adapter.Name) index=$($adapter.ifIndex)")
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            foreach ($entry in $dns) { $result.Add("dns_ipv4[$($adapter.ifIndex)]=$($entry.ServerAddresses -join ',')") }
        }
        foreach ($route in @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
            $result.Add("default_route_interface=$($route.InterfaceIndex) next_hop=$($route.NextHop) metric=$($route.RouteMetric)")
        }
    } catch {
        $result.Add("network_inventory_error=$($_.Exception.Message)")
    }
    return $result.ToArray()
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
$exe = Find-ZeonExe $ExePath
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($outputRoot)
$reportPath = Join-Path $outputRoot ('ZEON-network-recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$markerPath = [IO.Path]::ChangeExtension($reportPath, '.markers.txt')
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("started=$(Get-Date -Format o)")
$lines.Add("exe_version=$((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)")
$lines.Add('before:')
foreach ($line in @(Get-ProxySummary) + @(Get-NetworkSummary)) { $lines.Add($line) }

if (Get-Process -Name ZEON -ErrorAction SilentlyContinue) {
    Write-Host 'Fully exit ZEON from the tray, then press Enter.'
    [void](Read-Host)
}
if (Get-Process -Name ZEON -ErrorAction SilentlyContinue) {
    $lines.Add('recovery=skipped because ZEON is still running')
} else {
    # The application restores only its own exact loopback proxy state.
    $env:ZEON_STARTUP_DIAGNOSTICS_FILE = $markerPath
    $process = Start-Process -FilePath $exe -ArgumentList '--recover-system-proxy' `
        -WorkingDirectory (Split-Path -Parent $exe) -PassThru -Wait
    $lines.Add("recovery_exit_code=$($process.ExitCode)")
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $markerPath)) {
            if ($line -match 'marker=(proxy_recovery_[a-z_]+)') { $lines.Add("recovery_marker=$($Matches[1])") }
        }
    } else {
        $lines.Add('recovery_marker=missing')
    }
}

$lines.Add('after:')
foreach ($line in @(Get-ProxySummary) + @(Get-NetworkSummary)) { $lines.Add($line) }
$lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "Report: $reportPath"
$lines | Where-Object { $_ -match '^(wininet_|winhttp_|recovery_)' } | ForEach-Object { Write-Host $_ }
Write-Host 'Check whether normal websites now open with ZEON closed. If not, attach the report privately.'
