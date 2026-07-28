[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [string]$ManifestPath = "baselines/android-core/2026-07-28-baseline.json",

    [string]$AarPath,

    [switch]$SkipApkHash
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($Stream)
        return [System.BitConverter]::ToString($bytes).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-CoreEntries {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][ValidateSet("apk", "aar")][string]$Kind
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $pattern = if ($Kind -eq "apk") {
            "^lib/([^/]+)/libhiddify-core\.so$"
        } else {
            "^jni/([^/]+)/libhiddify-core\.so$"
        }

        $results = @()
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notmatch $pattern) {
                continue
            }
            $stream = $entry.Open()
            try {
                $results += [pscustomobject]@{
                    Abi = $Matches[1]
                    Sha256 = Get-Sha256Hex -Stream $stream
                    Size = $entry.Length
                    Entry = $entry.FullName
                }
            } finally {
                $stream.Dispose()
            }
        }
        return $results
    } finally {
        $archive.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedManifest = if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
    (Resolve-Path -LiteralPath $ManifestPath).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $repoRoot $ManifestPath)).Path
}
$manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
$apkManifest = if ($null -ne $manifest.PSObject.Properties["apk"]) {
    $manifest.apk
} else {
    $manifest.baseline_apk
}
$expectedByAbi = @{}
foreach ($abi in $manifest.aar.abis) {
    $expectedByAbi[$abi.name] = $abi
}

$resolvedAar = if ($AarPath) {
    (Resolve-Path -LiteralPath $AarPath).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path $repoRoot $manifest.aar.repository_path)).Path
}
$actualAarHash = Get-FileSha256Hex -Path $resolvedAar
if ($actualAarHash -ne $manifest.aar.sha256.ToUpperInvariant()) {
    throw "AAR SHA-256 mismatch: expected $($manifest.aar.sha256), got $actualAarHash"
}

$aarEntries = @(Get-CoreEntries -ArchivePath $resolvedAar -Kind aar)
if ($aarEntries.Count -ne $expectedByAbi.Count) {
    throw "AAR ABI count mismatch: expected $($expectedByAbi.Count), got $($aarEntries.Count)"
}
foreach ($entry in $aarEntries) {
    if (-not $expectedByAbi.ContainsKey($entry.Abi)) {
        throw "Unexpected AAR ABI: $($entry.Abi)"
    }
    $expected = $expectedByAbi[$entry.Abi]
    if ($entry.Sha256 -ne $expected.so_sha256.ToUpperInvariant()) {
        throw "AAR $($entry.Abi) libhiddify-core.so mismatch: expected $($expected.so_sha256), got $($entry.Sha256)"
    }
}

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
if (-not $SkipApkHash -and $apkManifest.sha256) {
    $actualApkHash = Get-FileSha256Hex -Path $resolvedApk
    if ($actualApkHash -ne $apkManifest.sha256.ToUpperInvariant()) {
        throw "APK SHA-256 mismatch: expected $($apkManifest.sha256), got $actualApkHash"
    }
}

$apkEntries = @(Get-CoreEntries -ArchivePath $resolvedApk -Kind apk)
if ($apkEntries.Count -eq 0) {
    throw "APK does not contain libhiddify-core.so"
}
$requiredAbis = @($apkManifest.abis)
foreach ($requiredAbi in $requiredAbis) {
    if ($requiredAbi -notin $apkEntries.Abi) {
        throw "APK is missing required ABI: $requiredAbi"
    }
}
foreach ($entry in $apkEntries) {
    if (-not $expectedByAbi.ContainsKey($entry.Abi)) {
        throw "APK contains unexpected hiddify-core ABI: $($entry.Abi)"
    }
    $expected = $expectedByAbi[$entry.Abi]
    $expectedApkHash = if ($null -ne $expected.PSObject.Properties["apk_so_sha256"]) {
        $expected.apk_so_sha256.ToUpperInvariant()
    } else {
        $expected.so_sha256.ToUpperInvariant()
    }
    if ($entry.Sha256 -ne $expectedApkHash) {
        throw "APK $($entry.Abi) libhiddify-core.so mismatch: expected $expectedApkHash, got $($entry.Sha256)"
    }
}

Write-Host "Verified AAR: $resolvedAar"
Write-Host "AAR SHA-256: $actualAarHash"
Write-Host "Verified APK: $resolvedApk"
foreach ($entry in $apkEntries) {
    Write-Host "  $($entry.Abi): $($entry.Sha256) ($($entry.Size) bytes)"
}
Write-Host "Core provenance verification passed."
