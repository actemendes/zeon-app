param(
    [string]$ExePath,
    [string]$OutputDirectory = $env:TEMP,
    [switch]$CollectOnly
)

$ErrorActionPreference = 'Stop'

function Find-ZeonExe {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "ZEON.exe not found: $ExplicitPath"
        }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    foreach ($process in @(Get-Process -Name ZEON -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) {
                return $process.Path
            }
        } catch { }
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\ZEON\ZEON.exe'),
        (Join-Path $env:LOCALAPPDATA 'ZEON\ZEON.exe'),
        (Join-Path $env:ProgramFiles 'ZEON\ZEON.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'ZEON\ZEON.exe'
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($entry in @(Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue)) {
            if ($entry.DisplayName -notmatch '^ZEON(?:\s|$)') { continue }
            if (-not $entry.InstallLocation) { continue }
            $candidate = Join-Path ([string]$entry.InstallLocation) 'ZEON.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    throw 'Cannot locate ZEON.exe. Rerun with -ExePath "C:\path\to\ZEON.exe".'
}

function Copy-LogSnapshot {
    param([string]$Source, [string]$Destination)

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    $parent = Split-Path -Parent $Destination
    [void][System.IO.Directory]::CreateDirectory($parent)
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [System.IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite')
        $outputStream = [System.IO.File]::Open($Destination, 'Create', 'Write', 'None')
        $inputStream.CopyTo($outputStream)
        return $true
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
}

function Add-LogFolder {
    param([string]$Root, [string]$Label, [string]$Destination, [System.Collections.Generic.List[string]]$Report)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $names = @('app.log', 'box.log', 'stderr.log', 'stderr.log.old',
        'stderr3.log', 'stderr3.log.old', 'stderr4.log', 'stderr4.log.old',
        'network_extension_error.log', 'network_extension_error.previous.log')
    foreach ($name in $names) {
        $relative = Join-Path $Label $name
        $source = Join-Path $Root $name
        try {
            if (Copy-LogSnapshot $source (Join-Path $Destination $relative)) {
                $Report.Add("copied $relative")
            }
        } catch {
            $Report.Add("failed $relative : $($_.Exception.Message)")
        }
    }
    $data = Join-Path $Root 'data'
    foreach ($name in @('box.log', 'stderr.log', 'stderr.log.old',
        'stderr3.log', 'stderr3.log.old', 'stderr4.log', 'stderr4.log.old')) {
        $relative = Join-Path (Join-Path $Label 'data') $name
        try {
            if (Copy-LogSnapshot (Join-Path $data $name) (Join-Path $Destination $relative)) {
                $Report.Add("copied $relative")
            }
        } catch {
            $Report.Add("failed $relative : $($_.Exception.Message)")
        }
    }
    $dbLog = Join-Path $data 'AppSettings.db\LOG'
    $relative = Join-Path (Join-Path $Label 'data\AppSettings.db') 'LOG'
    try {
        if (Copy-LogSnapshot $dbLog (Join-Path $Destination $relative)) {
            $Report.Add("copied $relative")
        }
    } catch {
        $Report.Add("failed $relative : $($_.Exception.Message)")
    }
}

if (-not [Environment]::OSVersion.Platform.Equals([PlatformID]::Win32NT)) {
    throw 'This script runs on Windows only.'
}

$resolvedExe = Find-ZeonExe $ExePath
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
[void][System.IO.Directory]::CreateDirectory($outputRoot)
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$session = Join-Path $outputRoot "ZEON-diagnostics-$stamp-$PID"
[void][System.IO.Directory]::CreateDirectory($session)
$report = [System.Collections.Generic.List[string]]::new()
$report.Add("collector_started=$(Get-Date -Format o)")
$report.Add("exe=$resolvedExe")
$report.Add("exe_sha256=$((Get-FileHash -LiteralPath $resolvedExe -Algorithm SHA256).Hash)")
$report.Add("exe_version=$((Get-Item -LiteralPath $resolvedExe).VersionInfo.ProductVersion)")
$report.Add("windows_version=$([Environment]::OSVersion.VersionString)")
$markerFile = Join-Path $session 'startup-markers.txt'

if (-not $CollectOnly) {
    if (Get-Process -Name ZEON -ErrorAction SilentlyContinue) {
        Write-Host 'Fully exit ZEON from the system tray, then press Enter.'
        [void](Read-Host)
    }
    if (Get-Process -Name ZEON -ErrorAction SilentlyContinue) {
        throw 'ZEON is still running. Exit it completely and rerun the script.'
    }

    # Both the native runner and Dart startup probes read this inherited variable.
    $env:ZEON_STARTUP_DIAGNOSTICS_FILE = $markerFile
    $report.Add("launch_requested=$(Get-Date -Format o)")
    Write-Host 'Launching ZEON. After its window opens, connect once. Press Enter after it connects.'
    $started = Start-Process -FilePath $resolvedExe -WorkingDirectory (Split-Path -Parent $resolvedExe) -PassThru
    $report.Add("launched_pid=$($started.Id)")
    [void](Read-Host)
    $report.Add("capture_requested=$(Get-Date -Format o)")
}

$roots = @(
    @{ Path = (Join-Path $env:APPDATA 'ZEON\ZEON'); Name = 'roaming' },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'ZEON\ZEON'); Name = 'local' },
    @{ Path = (Join-Path (Split-Path -Parent $resolvedExe) 'zeon_portable_data'); Name = 'portable' }
)
foreach ($root in $roots) {
    Add-LogFolder $root.Path $root.Name $session $report
}

if (Test-Path -LiteralPath $markerFile -PathType Leaf) {
    $report.Add('startup_markers=present')
} else {
    $report.Add('startup_markers=missing; check that the selected EXE contains the startup probes')
}
$report | Set-Content -LiteralPath (Join-Path $session 'capture-report.txt') -Encoding UTF8
$zipPath = "$session.zip"
Compress-Archive -Path (Join-Path $session '*') -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Diagnostics archive: $zipPath"
Write-Host 'The archive may contain server addresses and profile details. Share it privately.'
