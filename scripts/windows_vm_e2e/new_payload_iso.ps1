[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$BindHarnessPath,
    [Parameter(Mandatory = $true)][string]$ProxyTestPath,
    [Parameter(Mandatory = $true)][string]$TestRootCertificatePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [switch]$UnsignedDevelopmentBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$inputs = @(
    $InstallerPath,
    $BindHarnessPath,
    $ProxyTestPath,
    $TestRootCertificatePath
)
foreach ($inputPath in $inputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "VM payload input was not found: $inputPath"
    }
}

if (-not ('ZeonVmPayloadIsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ZeonVmPayloadIsoWriter {
    public static void Save(object value, string path) {
        IStream stream = (IStream)value;
        byte[] buffer = new byte[64 * 1024];
        IntPtr read = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (var output = new FileStream(path, FileMode.Create,
                                                FileAccess.Write, FileShare.None)) {
                while (true) {
                    Marshal.WriteInt32(read, 0);
                    stream.Read(buffer, buffer.Length, read);
                    int count = Marshal.ReadInt32(read);
                    if (count <= 0) break;
                    output.Write(buffer, 0, count);
                }
            }
        } finally {
            Marshal.FreeHGlobal(read);
        }
    }
}
'@
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ("zeon-vm-payload-" + [guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($staging) | Out-Null
try {
    $payloadFiles = @(
        @{ Source = $InstallerPath; Name = "ZEON-Windows-Setup-x64.exe" },
        @{ Source = $BindHarnessPath; Name = "windows_bind_e2e.exe" },
        @{ Source = $ProxyTestPath; Name = "proxy_windows_test.exe" },
        @{ Source = $TestRootCertificatePath; Name = "zeon-e2e-root.cer" }
    )
    foreach ($item in $payloadFiles) {
        Copy-Item -LiteralPath $item.Source -Destination (Join-Path $staging $item.Name)
    }

    $manifestFiles = foreach ($item in $payloadFiles) {
        $file = Get-Item -LiteralPath (Join-Path $staging $item.Name)
        $signature = if ($file.Extension -eq ".exe") {
            Get-AuthenticodeSignature -LiteralPath $file.FullName
        } else { $null }
        [ordered]@{
            path = $file.Name
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            signature_status = if ($signature) { $signature.Status.ToString() } else { "NotApplicable" }
            signer_thumbprint = if ($signature -and $signature.SignerCertificate) {
                $signature.SignerCertificate.Thumbprint
            } else { $null }
            timestamp_present = [bool]($signature -and $signature.TimeStamperCertificate)
        }
    }
    $manifest = [ordered]@{
        schema = 1
        generated_at_utc = [DateTime]::UtcNow.ToString("o")
        unsigned_development_build = [bool]$UnsignedDevelopmentBuild
        files = @($manifestFiles)
    }
    $manifest | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $staging "ZEON-Windows-Release-Manifest.json") -Encoding UTF8

    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $outputFullPath
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $fileSystemImage = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fileSystemImage.FileSystemsToCreate = 3 # ISO9660 | Joliet
    $fileSystemImage.VolumeName = "ZEON_PAYLOAD"
    $fileSystemImage.Root.AddTree($staging, $false)
    $result = $fileSystemImage.CreateResultImage()
    $imageStream = $result.ImageStream
    [ZeonVmPayloadIsoWriter]::Save($imageStream, $outputFullPath)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($imageStream)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($result)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($fileSystemImage)
    $imageStream = $null
    $result = $null
    $fileSystemImage = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    Get-Item -LiteralPath $outputFullPath | Select-Object `
        FullName,
        Length,
        @{ Name = "SHA256"; Expression = { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        [IO.Directory]::Delete($staging, $true)
    }
}
