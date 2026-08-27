[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidatePattern('^[A-Z0-9_]{1,32}$')][string]$VolumeName = "ZEON_E2E"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
    throw "Guest tools source directory was not found: $SourceDirectory"
}
if (-not (Get-ChildItem -LiteralPath $SourceDirectory -File)) {
    throw "Guest tools source directory is empty: $SourceDirectory"
}

if (-not ("ZeonGuestToolsIsoWriter" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ZeonGuestToolsIsoWriter {
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

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory((Split-Path -Parent $outputFullPath)) | Out-Null
$image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
try {
    $image.FileSystemsToCreate = 3 # ISO9660 | Joliet
    $image.VolumeName = $VolumeName
    $image.Root.AddTree([IO.Path]::GetFullPath($SourceDirectory), $false)
    $result = $image.CreateResultImage()
    try {
        [ZeonGuestToolsIsoWriter]::Save($result.ImageStream, $outputFullPath)
    } finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($result)
    }
} finally {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($image)
}

Get-Item -LiteralPath $outputFullPath | Select-Object FullName, Length,
    @{ Name = "SHA256"; Expression = { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
