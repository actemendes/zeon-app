[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$CorePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "hiddify-core\bin\hiddify-core.dll")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
    throw "Windows native core is missing: $CorePath. Rebuild it with scripts/rebuild_hiddify_core.ps1 -Platform windows."
}

& git -C $RepoRoot diff --quiet -- hiddify-core
if ($LASTEXITCODE -ne 0) {
    throw "Uncommitted hiddify-core changes prevent native provenance verification."
}
& git -C $RepoRoot diff --cached --quiet -- hiddify-core
if ($LASTEXITCODE -ne 0) {
    throw "Staged hiddify-core changes prevent native provenance verification."
}
$expectedTree = (& git -C $RepoRoot rev-parse "HEAD:hiddify-core").Trim()
if ($LASTEXITCODE -ne 0 -or -not $expectedTree) {
    throw "Could not resolve the hiddify-core Git tree."
}

if (-not ("ZeonWindowsCoreMetadataReader" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ZeonWindowsCoreMetadataReader {
    [DllImport("kernel32.dll", EntryPoint = "LoadLibraryW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibrary(string path);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr GetMetadata();

    public static string Read(string path) {
        IntPtr module = LoadLibrary(path);
        if (module == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load Windows native core");
        }
        IntPtr proc = GetProcAddress(module, "getBuildMetadata");
        if (proc == IntPtr.Zero) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Native core has no build metadata export");
        }
        var getMetadata = (GetMetadata)Marshal.GetDelegateForFunctionPointer(proc, typeof(GetMetadata));
        IntPtr json = getMetadata();
        if (json == IntPtr.Zero) {
            throw new InvalidOperationException("Native core returned empty build metadata");
        }
        return Marshal.PtrToStringAnsi(json);
    }
}
'@
}

$metadata = [ZeonWindowsCoreMetadataReader]::Read([System.IO.Path]::GetFullPath($CorePath)) | ConvertFrom-Json
if ($metadata.hiddify_core_tree -ne $expectedTree) {
    throw "Stale Windows native core: embedded tree $($metadata.hiddify_core_tree), expected $expectedTree. Rebuild with scripts/rebuild_hiddify_core.ps1 -Platform windows."
}
if ($metadata.source_dirty -ne "false") {
    throw "Windows native core was built from dirty source: $($metadata.source_dirty)."
}
if ($metadata.build_tags -match '(^|,)(smart_active_debug|zeon_route_validation|zeon_ru_remote_dns_baseline)(,|$)') {
    throw "Windows native core contains validation-only build tags."
}

$hash = (Get-FileHash -LiteralPath $CorePath -Algorithm SHA256).Hash
Write-Host "Windows native core verified: tree=$expectedTree sha256=$hash"
