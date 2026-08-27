[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$QemuDirectory,
    [Parameter(Mandatory = $true)][string]$VmDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$VmName = "windows-11-e2e",
    [string]$DiskPath,
    [string]$WindowsIso,
    [string]$PayloadIso,
    [switch]$AttachAnswerDrive,
    [ValidateSet("whpx", "tcg")]
    [string]$Accelerator = "whpx",
    [ValidateSet("host", "max", "Haswell-noTSX")]
    [string]$CpuModel = "host",
    [ValidateSet("nvme", "ide")]
    [string]$DiskInterface = "nvme",
    [ValidateSet("e1000e", "rtl8139")]
    [string]$NetworkModel = "e1000e",
    [switch]$UseLegacyInput,
    [ValidateRange(1, 8)][int]$VirtualCpuCount = 4,
    [ValidateRange(4096, 16384)][int]$MemoryMegabytes = 6144,
    [int]$WinRmHostPort = 55985,
    [int]$QmpHostPort = 54444,
    [int]$VncDisplay = 1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$qemu = Join-Path $QemuDirectory "qemu-system-x86_64.exe"
$disk = if ($DiskPath) {
    [IO.Path]::GetFullPath($DiskPath)
} else {
    Join-Path $VmDirectory "$VmName.qcow2"
}
$firmwareCode = Join-Path $QemuDirectory "share\edk2-x86_64-code.fd"
$firmwareVars = Join-Path $VmDirectory "edk2-vars.fd"
$answerIso = Join-Path $VmDirectory "answer.iso"
foreach ($required in @($qemu, $disk, $firmwareCode, $firmwareVars)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required VM file was not found: $required"
    }
}
if (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $WinRmHostPort,$QmpHostPort -State Listen -ErrorAction SilentlyContinue) {
    throw "A required localhost VM port is already in use."
}

$acceleratorOptions = if ($Accelerator -eq "whpx") {
    "whpx,kernel-irqchip=off"
} else {
    "tcg,thread=multi"
}
$effectiveCpuModel = if ($Accelerator -eq "tcg") { "max" } else { $CpuModel }

$systemDiskArguments = if ($DiskInterface -eq "ide") {
    @("-drive", "file=$disk,format=qcow2,if=ide,cache=writeback")
} else {
    @(
        "-drive", "file=$disk,format=qcow2,if=none,id=systemdisk,cache=writeback",
        "-device", "nvme,drive=systemdisk,serial=ZEONWIN11E2E"
    )
}

$arguments = @(
    "-name", "ZEON-$VmName",
    "-machine", "q35",
    # WHPX's userspace interrupt delivery avoids a Windows PE boot stall seen
    # on hosts where the hypervisor does not expose kernel irqchip support.
    "-accel", $acceleratorOptions,
    "-cpu", $effectiveCpuModel,
    "-smp", "$VirtualCpuCount",
    "-m", "$MemoryMegabytes",
    "-drive", "if=pflash,format=raw,readonly=on,file=$firmwareCode",
    "-drive", "if=pflash,format=raw,file=$firmwareVars"
)
$arguments += $systemDiskArguments
$arguments += @(
    "-nic", "user,model=${NetworkModel},hostfwd=tcp:127.0.0.1:${WinRmHostPort}-:5985",
    "-qmp", "tcp:127.0.0.1:${QmpHostPort},server=on,wait=off",
    "-vnc", "127.0.0.1:$VncDisplay",
    "-display", "none"
)
if (-not $UseLegacyInput) {
    $arguments += @(
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-tablet,bus=xhci.0",
        # Keep firmware/setup keyboard input available without a VNC client.
        "-device", "usb-kbd,bus=xhci.0"
    )
}
if ($WindowsIso) {
    if (-not (Test-Path -LiteralPath $WindowsIso -PathType Leaf)) {
        throw "Windows ISO was not found: $WindowsIso"
    }
    $arguments += @("-drive", "file=$WindowsIso,media=cdrom,readonly=on", "-boot", "order=d,once=d")
}
if ($PayloadIso) {
    if (-not (Test-Path -LiteralPath $PayloadIso -PathType Leaf)) {
        throw "Payload ISO was not found: $PayloadIso"
    }
    # Keep the VM payload read-only. This transports test artifacts into the
    # guest without exposing a host file share or changing host networking.
    $arguments += @("-drive", "file=$PayloadIso,media=cdrom,readonly=on")
}
if ($AttachAnswerDrive) {
    if (-not (Test-Path -LiteralPath $answerIso -PathType Leaf)) {
        throw "Answer ISO was not found: $answerIso"
    }
    # Present the answer file as read-only optical media. Windows PE did not
    # mount QEMU's synthetic USB FAT device reliably on the tested 25H2 image.
    $arguments += @("-drive", "file=$answerIso,media=cdrom,readonly=on")
}

$stdout = Join-Path $VmDirectory "qemu.stdout.log"
$stderr = Join-Path $VmDirectory "qemu.stderr.log"
$process = Start-Process -FilePath $qemu -ArgumentList $arguments -WindowStyle Hidden `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Set-Content -LiteralPath (Join-Path $VmDirectory "qemu.pid") -Value $process.Id -NoNewline
[pscustomobject]@{ ProcessId = $process.Id; QmpPort = $QmpHostPort; WinRmPort = $WinRmHostPort; VncPort = 5900 + $VncDisplay }
