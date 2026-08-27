[CmdletBinding()]
param(
    [ValidateSet("Matrix", "PrepareReboot", "CollectReboot")]
    [string]$Mode = "Matrix",
    [string]$OutputDirectory = "C:\ZEON-E2E"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$internetSettings = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$recoveryKey = "HKCU:\Software\ZEON\SystemProxyRecovery"
$runOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$runOnceName = "ZEONSystemProxyRecovery"
$zeonExecutable = Join-Path $env:LOCALAPPDATA "Programs\ZEON\ZEON.exe"

if (-not ("ZeonE2EWinInet" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ZeonE2EWinInet {
    [StructLayout(LayoutKind.Sequential)]
    private struct PerConnectionOption {
        public uint Option;
        public IntPtr Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PerConnectionOptionList {
        public uint Size;
        public IntPtr Connection;
        public uint OptionCount;
        public uint OptionError;
        public IntPtr Options;
    }

    [DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOptionW(
        IntPtr internet, int option, IntPtr buffer, int length);

    [DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetQueryOptionW(
        IntPtr internet, int option, ref PerConnectionOptionList buffer,
        ref uint length);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(IntPtr value);

    private static void ThrowLastError(string operation) {
        throw new System.ComponentModel.Win32Exception(
            Marshal.GetLastWin32Error(), operation);
    }

    private static PerConnectionOption[] NewOptions() {
        return new PerConnectionOption[] {
            new PerConnectionOption { Option = 1 },
            new PerConnectionOption { Option = 2 },
            new PerConnectionOption { Option = 3 },
            new PerConnectionOption { Option = 4 }
        };
    }

    private static IntPtr MarshalOptions(PerConnectionOption[] options) {
        int optionSize = Marshal.SizeOf(typeof(PerConnectionOption));
        IntPtr pointer = Marshal.AllocHGlobal(optionSize * options.Length);
        for (int index = 0; index < options.Length; ++index) {
            Marshal.StructureToPtr(options[index],
                IntPtr.Add(pointer, index * optionSize), false);
        }
        return pointer;
    }

    public static string[] Query() {
        PerConnectionOption[] options = NewOptions();
        IntPtr optionPointer = MarshalOptions(options);
        try {
            PerConnectionOptionList list = new PerConnectionOptionList {
                Size = (uint)Marshal.SizeOf(typeof(PerConnectionOptionList)),
                OptionCount = (uint)options.Length,
                Options = optionPointer
            };
            uint size = list.Size;
            if (!InternetQueryOptionW(IntPtr.Zero, 75, ref list, ref size)) {
                ThrowLastError("InternetQueryOptionW");
            }
            int optionSize = Marshal.SizeOf(typeof(PerConnectionOption));
            for (int index = 0; index < options.Length; ++index) {
                options[index] = (PerConnectionOption)Marshal.PtrToStructure(
                    IntPtr.Add(optionPointer, index * optionSize),
                    typeof(PerConnectionOption));
            }
            string server = Marshal.PtrToStringUni(options[1].Value) ?? "";
            string bypass = Marshal.PtrToStringUni(options[2].Value) ?? "";
            string pac = Marshal.PtrToStringUni(options[3].Value) ?? "";
            for (int index = 1; index < options.Length; ++index) {
                if (options[index].Value != IntPtr.Zero) GlobalFree(options[index].Value);
            }
            return new string[] {
                unchecked((uint)options[0].Value.ToInt64()).ToString(),
                server,
                bypass,
                pac
            };
        } finally {
            Marshal.FreeHGlobal(optionPointer);
        }
    }

    public static void Set(uint flags, string server, string bypass, string pac) {
        IntPtr serverPointer = Marshal.StringToHGlobalUni(server ?? "");
        IntPtr bypassPointer = Marshal.StringToHGlobalUni(bypass ?? "");
        IntPtr pacPointer = Marshal.StringToHGlobalUni(pac ?? "");
        PerConnectionOption[] options = NewOptions();
        options[0].Value = new IntPtr(unchecked((long)flags));
        options[1].Value = serverPointer;
        options[2].Value = bypassPointer;
        options[3].Value = pacPointer;
        IntPtr optionPointer = MarshalOptions(options);
        try {
            PerConnectionOptionList list = new PerConnectionOptionList {
                Size = (uint)Marshal.SizeOf(typeof(PerConnectionOptionList)),
                OptionCount = (uint)options.Length,
                Options = optionPointer
            };
            int listSize = Marshal.SizeOf(typeof(PerConnectionOptionList));
            IntPtr listPointer = Marshal.AllocHGlobal(listSize);
            try {
                Marshal.StructureToPtr(list, listPointer, false);
                if (!InternetSetOptionW(IntPtr.Zero, 75, listPointer, listSize)) {
                    ThrowLastError("InternetSetOptionW per-connection");
                }
            } finally {
                Marshal.FreeHGlobal(listPointer);
            }
        } finally {
            Marshal.FreeHGlobal(optionPointer);
            Marshal.FreeHGlobal(serverPointer);
            Marshal.FreeHGlobal(bypassPointer);
            Marshal.FreeHGlobal(pacPointer);
        }
        Refresh();
    }

    public static void Refresh() {
        int[] options = new int[] { 39, 95, 37 };
        foreach (int option in options) {
            if (!InternetSetOptionW(IntPtr.Zero, option, IntPtr.Zero, 0)) {
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(), "InternetSetOptionW " + option);
            }
        }
    }
}
'@
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$logPath = Join-Path $OutputDirectory ("proxy-recovery-{0}-{1}.log" -f $Mode, (Get-Date -Format "yyyyMMdd-HHmmss"))
$jsonPath = [IO.Path]::ChangeExtension($logPath, ".json")
$results = [Collections.Generic.List[object]]::new()

function Write-Evidence([string]$message) {
    $safe = "[{0:O}] {1}" -f [DateTime]::UtcNow, $message
    Add-Content -LiteralPath $logPath -Value $safe -Encoding UTF8
    Write-Host $safe
}

function Set-StringValue([string]$path, [string]$name, [string]$value) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType String -Value $value -Force | Out-Null
}

function Set-DwordValue([string]$path, [string]$name, [uint32]$value) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $value -Force | Out-Null
}

function Set-QwordValue([string]$path, [string]$name, [uint64]$value) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType QWord -Value $value -Force | Out-Null
}

function Get-StringValue([string]$path, [string]$name) {
    try {
        $value = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name
        if ($null -eq $value) { return "" }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ProxyState {
    $values = [ZeonE2EWinInet]::Query()
    $flags = [uint32]$values[0]
    [ordered]@{
        flags = $flags
        proxy_enable = if (($flags -band 2) -ne 0) { 1 } else { 0 }
        proxy_server = $values[1]
        proxy_bypass = $values[2]
        auto_config_url = $values[3]
    }
}

function Set-ProxyState(
    [uint32]$flags,
    [string]$proxyServer,
    [string]$proxyBypass,
    [string]$autoConfigUrl
) {
    [ZeonE2EWinInet]::Set($flags, $proxyServer, $proxyBypass, $autoConfigUrl)
}

function Remove-RecoveryState {
    Remove-Item -LiteralPath $recoveryKey -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $runOnceKey -Name $runOnceName -Force -ErrorAction SilentlyContinue
}

function Set-RecoveryMarker(
    [hashtable]$baseline,
    [hashtable]$expected,
    [uint32]$ownerPid = 424242,
    [uint64]$ownerCreationTime = 1,
    [uint64]$generation = 1,
    [uint32]$mixedPort = 55432
) {
    Remove-RecoveryState
    New-Item -Path $recoveryKey -Force | Out-Null
    Set-DwordValue $recoveryKey "Armed" 0
    Set-DwordValue $recoveryKey "Schema" 1
    Set-DwordValue $recoveryKey "OwnerPid" $ownerPid
    Set-QwordValue $recoveryKey "OwnerCreationTime" $ownerCreationTime
    Set-QwordValue $recoveryKey "Generation" $generation
    Set-DwordValue $recoveryKey "MixedPort" $mixedPort
    Set-StringValue $recoveryKey "ExecutablePath" $zeonExecutable
    foreach ($prefix in @("Baseline", "Expected")) {
        $state = if ($prefix -eq "Baseline") { $baseline } else { $expected }
        Set-DwordValue $recoveryKey ($prefix + "Flags") ([uint32]$state.flags)
        Set-StringValue $recoveryKey ($prefix + "ProxyServer") ([string]$state.proxy_server)
        Set-StringValue $recoveryKey ($prefix + "ProxyBypass") ([string]$state.proxy_bypass)
        Set-StringValue $recoveryKey ($prefix + "AutoConfigURL") ([string]$state.auto_config_url)
    }
    if (-not (Test-Path -LiteralPath $runOnceKey)) {
        New-Item -Path $runOnceKey -Force | Out-Null
    }
    Set-StringValue $runOnceKey $runOnceName ('"' + $zeonExecutable + '" --recover-system-proxy')
    Set-DwordValue $recoveryKey "Armed" 1
}

function Invoke-Recovery {
    if (-not (Test-Path -LiteralPath $zeonExecutable -PathType Leaf)) {
        throw "Installed ZEON runner was not found"
    }
    $process = Start-Process -FilePath $zeonExecutable -ArgumentList "--recover-system-proxy" -Wait -PassThru
    return $process.ExitCode
}

function Test-Internet {
    $curl = Start-Process -FilePath "$env:SystemRoot\System32\curl.exe" `
        -ArgumentList @("-I", "--max-time", "20", "https://www.microsoft.com") `
        -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $OutputDirectory "curl.out") `
        -RedirectStandardError (Join-Path $OutputDirectory "curl.err")
    return $curl.ExitCode
}

function Marker-Exists {
    return Test-Path -LiteralPath $recoveryKey
}

function Add-Result([string]$scenario, [bool]$passed, [object]$after, [hashtable]$details) {
    $item = [ordered]@{
        scenario = $scenario
        passed = $passed
        proxy_after = $after
        marker_exists_after = Marker-Exists
        details = $details
    }
    $results.Add([pscustomobject]$item)
    Write-Evidence ("{0}: {1}" -f $scenario, $(if ($passed) { "PASS" } else { "FAIL" }))
}

$direct = @{ flags = 1; proxy_server = ""; proxy_bypass = ""; auto_config_url = "" }
$zeonExpected = @{ flags = 3; proxy_server = "http://127.0.0.1:55432"; proxy_bypass = ""; auto_config_url = "" }

try {
    Write-Evidence "Mode=$Mode; guest=$([Environment]::OSVersion.VersionString); runner_present=$(Test-Path -LiteralPath $zeonExecutable)"
    if (Test-Path -LiteralPath $zeonExecutable) {
        Write-Evidence "runner_sha256=$((Get-FileHash -LiteralPath $zeonExecutable -Algorithm SHA256).Hash)"
    }

    switch ($Mode) {
        "Matrix" {
            Set-ProxyState @direct
            Set-RecoveryMarker -baseline $direct -expected $zeonExpected
            Set-ProxyState @zeonExpected
            $exitCode = Invoke-Recovery
            $after = Get-ProxyState
            $internetExit = Test-Internet
            Add-Result "stale-direct-recovery" `
                ($exitCode -eq 0 -and $after.proxy_enable -eq 0 -and -not (Marker-Exists) -and $internetExit -eq 0) `
                $after @{ runner_exit = $exitCode; internet_exit = $internetExit }

            $manual = @{ flags = 3; proxy_server = "http://127.0.0.1:61080"; proxy_bypass = "<local>"; auto_config_url = "" }
            $manualExpected = @{ flags = 3; proxy_server = $zeonExpected.proxy_server; proxy_bypass = $manual.proxy_bypass; auto_config_url = "" }
            Set-ProxyState @manual
            Set-RecoveryMarker -baseline $manual -expected $manualExpected -generation 2
            Set-ProxyState @manualExpected
            $exitCode = Invoke-Recovery
            $after = Get-ProxyState
            Add-Result "manual-proxy-baseline-restoration" `
                ($exitCode -eq 0 -and $after.proxy_enable -eq 1 -and $after.proxy_server -eq $manual.proxy_server -and $after.proxy_bypass -eq $manual.proxy_bypass -and -not (Marker-Exists)) `
                $after @{ runner_exit = $exitCode }
            Set-ProxyState @direct

            $pac = @{ flags = 5; proxy_server = ""; proxy_bypass = ""; auto_config_url = "http://127.0.0.1:61888/zeon-e2e.pac" }
            $pacExpected = @{ flags = 3; proxy_server = $zeonExpected.proxy_server; proxy_bypass = ""; auto_config_url = $pac.auto_config_url }
            Set-ProxyState @pac
            Set-RecoveryMarker -baseline $pac -expected $pacExpected -generation 3
            Set-ProxyState @pacExpected
            $exitCode = Invoke-Recovery
            $after = Get-ProxyState
            Add-Result "pac-baseline-restoration" `
                ($exitCode -eq 0 -and $after.flags -eq $pac.flags -and $after.proxy_enable -eq 0 -and $after.auto_config_url -eq $pac.auto_config_url -and -not (Marker-Exists)) `
                $after @{ runner_exit = $exitCode }
            Set-ProxyState @direct

            $foreign = @{ flags = 3; proxy_server = "http://127.0.0.1:65001"; proxy_bypass = "<local>"; auto_config_url = "" }
            Set-RecoveryMarker -baseline $direct -expected $zeonExpected -generation 4
            Set-ProxyState @foreign
            $exitCode = Invoke-Recovery
            $after = Get-ProxyState
            Add-Result "foreign-loopback-preserved" `
                ($exitCode -eq 0 -and $after.proxy_enable -eq 1 -and $after.proxy_server -eq $foreign.proxy_server -and $after.proxy_bypass -eq $foreign.proxy_bypass -and -not (Marker-Exists)) `
                $after @{ runner_exit = $exitCode }
            Set-ProxyState @direct
        }
        "PrepareReboot" {
            # Disable only ZEON's ordinary per-user autostart. The recovery
            # RunOnce remains armed and is the only ZEON process expected at logon.
            $disabled = @()
            $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
            if (Test-Path -LiteralPath $runKey) {
                $values = Get-ItemProperty -LiteralPath $runKey
                foreach ($property in $values.PSObject.Properties) {
                    if ($property.Name -notmatch '^PS' -and [string]$property.Value -match '(?i)ZEON') {
                        $disabled += [ordered]@{ location = $runKey; name = $property.Name; value = [string]$property.Value }
                        Remove-ItemProperty -LiteralPath $runKey -Name $property.Name -Force
                    }
                }
            }
            $startup = [Environment]::GetFolderPath("Startup")
            Get-ChildItem -LiteralPath $startup -ErrorAction SilentlyContinue |
                Where-Object Name -Match '(?i)ZEON' | ForEach-Object {
                    $target = $_.FullName + ".e2e-disabled"
                    Rename-Item -LiteralPath $_.FullName -NewName ([IO.Path]::GetFileName($target))
                    $disabled += [ordered]@{ location = $startup; name = $_.Name; value = $target }
                }
            $disabled | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "disabled-autostart.json") -Encoding UTF8

            Get-Process ZEON,ZEONCli -ErrorAction SilentlyContinue | Stop-Process -Force
            Set-ProxyState @direct
            Set-RecoveryMarker -baseline $direct -expected $zeonExpected -generation 5
            Set-ProxyState @zeonExpected
            $before = Get-ProxyState
            $prepared = $before.proxy_enable -eq 1 -and $before.proxy_server -eq $zeonExpected.proxy_server -and (Marker-Exists)
            Add-Result "reboot-recovery-prepared" $prepared $before @{ autostart_disabled = $disabled.Count; run_once_armed = $true }
        }
        "CollectReboot" {
            $after = Get-ProxyState
            $internetExit = Test-Internet
            $zeonRunning = @(Get-Process ZEON -ErrorAction SilentlyContinue).Count
            $runOncePresent = $false
            try {
                $null = Get-ItemPropertyValue -LiteralPath $runOnceKey -Name $runOnceName -ErrorAction Stop
                $runOncePresent = $true
            } catch {}
            Add-Result "reboot-before-manual-zeon" `
                ($after.proxy_enable -eq 0 -and -not (Marker-Exists) -and -not $runOncePresent -and $internetExit -eq 0 -and $zeonRunning -eq 0) `
                $after @{
                    internet_exit = $internetExit
                    zeon_process_count = $zeonRunning
                    run_once_present = $runOncePresent
                }
        }
    }
} finally {
    if ($Mode -ne "PrepareReboot") {
        # Never leave a synthetic proxy active after a completed test mode.
        Set-ProxyState @direct
    }
    $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Evidence "results_json=$jsonPath"
}

if (@($results | Where-Object { -not $_.passed }).Count -ne 0) {
    exit 1
}
