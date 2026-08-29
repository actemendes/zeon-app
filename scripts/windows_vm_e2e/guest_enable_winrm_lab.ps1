[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This disposable-VM bootstrap must run from an elevated PowerShell session."
}

# The VM is reachable only through QEMU's localhost-bound host-forward. Allow
# its local administrator to receive an elevated WinRM token for lab control.
Set-ItemProperty `
    -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name LocalAccountTokenFilterPolicy `
    -Type DWord `
    -Value 1 `
    -Force

# The preserved image already has a localhost-forwarded WinRM listener. Keep
# transport authentication on NTLM and do not enable Basic or unencrypted
# message transport. Enable-PSRemoting can wait on network-profile discovery
# for several minutes in the deliberately slow TCG guest and is unnecessary
# for this disposable overlay.
$winrmService = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Service"
$winrmAuth = Join-Path $winrmService "Auth"
New-Item -Path $winrmAuth -Force | Out-Null
New-ItemProperty -Path $winrmService -Name AllowUnencrypted `
    -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $winrmAuth -Name Basic `
    -PropertyType DWord -Value 0 -Force | Out-Null
Set-Service -Name WinRM -StartupType Automatic
Restart-Service -Name WinRM -Force

"ready" | Set-Content -LiteralPath "C:\firewall-e2e-winrm-ready.txt" -Encoding ASCII
