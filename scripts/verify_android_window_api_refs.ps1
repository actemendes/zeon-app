[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ArtifactPath,

    [switch]$AllowMatches
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Keep the production-sized method_id loop in compiled code. The surrounding
# PowerShell remains the stable CLI and ZIP orchestration surface.
if ($null -eq ('ZeonWindowDexMethodScanner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

public static class ZeonWindowDexMethodScanner
{
    const string Window = "Landroid/view/Window;";
    static readonly HashSet<string> Forbidden = new HashSet<string>(StringComparer.Ordinal) {
        "Landroid/view/Window;->setStatusBarColor(I)V",
        "Landroid/view/Window;->setNavigationBarColor(I)V",
        "Landroid/view/Window;->setNavigationBarDividerColor(I)V"
    };

    public static string[] Scan(byte[] b, string label)
    {
        Need(b, 0, 0x70, "header");
        if (b[0] != 0x64 || b[1] != 0x65 || b[2] != 0x78 || b[3] != 0x0a ||
            b[4] < 0x30 || b[4] > 0x39 || b[5] < 0x30 || b[5] > 0x39 ||
            b[6] < 0x30 || b[6] > 0x39 || b[7] != 0)
            Bad("invalid magic/version in " + label);
        uint fileSize = U4(b, 0x20, "file_size"), headerSize = U4(b, 0x24, "header_size");
        uint endian = U4(b, 0x28, "endian_tag");
        if (fileSize != (uint)b.LongLength) Bad("file_size does not match the entry length");
        if (headerSize != 0x70) Bad("unsupported header_size " + headerSize);
        if (endian != 0x12345678) Bad("unsupported endian_tag 0x" + endian.ToString("x8"));

        uint ss = U4(b, 0x38, "string_ids_size"), so = U4(b, 0x3c, "string_ids_off");
        uint ts = U4(b, 0x40, "type_ids_size"), to = U4(b, 0x44, "type_ids_off");
        uint ps = U4(b, 0x48, "proto_ids_size"), po = U4(b, 0x4c, "proto_ids_off");
        uint ms = U4(b, 0x58, "method_ids_size"), mo = U4(b, 0x5c, "method_ids_off");
        Table(b, ss, so, 4, "string_ids"); Table(b, ts, to, 4, "type_ids");
        Table(b, ps, po, 12, "proto_ids"); Table(b, ms, mo, 8, "method_ids");
        if (ts > UInt16.MaxValue || ps > UInt16.MaxValue)
            Bad("type/proto table exceeds the UInt16 method_id index range");

        var strings = new Dictionary<uint, string>();
        var types = new Dictionary<uint, string>();
        int windowType = -1;
        uint previousDescriptorIndex = 0;
        for (uint i = 0; i < ts; i++) {
            uint descriptorIndex = U4(b, (long)to + 4L * i, "type descriptor_idx");
            if (descriptorIndex >= ss) Bad("type descriptor_idx exceeds string_ids_size");
            if (i != 0 && descriptorIndex <= previousDescriptorIndex) Bad("type_ids are not ordered");
            previousDescriptorIndex = descriptorIndex;
            string descriptor = Type(b, i, ts, to, ss, so, strings, types);
            ValidateType(descriptor, true);
            if (String.Equals(descriptor, Window, StringComparison.Ordinal)) windowType = (int)i;
        }

        var protos = new Dictionary<uint, string>();
        var hits = new List<string>();
        for (uint i = 0; i < ms; i++) {
            long at = (long)mo + 8L * i;
            ushort ci = U2(b, at, "method class_idx"), pi = U2(b, at + 2, "method proto_idx");
            uint ni = U4(b, at + 4, "method name_idx");
            if (ci >= ts || pi >= ps || ni >= ss) Bad("method_id index exceeds its table");
            if (windowType < 0 || ci != windowType) continue;
            string name = Str(b, ni, ss, so, strings);
            string proto = Proto(b, pi, ps, po, ts, to, ss, so, strings, types, protos);
            string signature = Window + "->" + name + proto;
            if (Forbidden.Contains(signature)) hits.Add(label + " | method_id[" + i + "] | " + signature);
        }
        hits.Sort(StringComparer.Ordinal);
        return hits.ToArray();
    }

    static string Proto(byte[] b, uint i, uint ps, uint po, uint ts, uint to,
        uint ss, uint so, Dictionary<uint,string> strings, Dictionary<uint,string> types,
        Dictionary<uint,string> cache)
    {
        string found; if (cache.TryGetValue(i, out found)) return found;
        if (i >= ps) Bad("invalid proto index");
        long at = (long)po + 12L * i;
        uint shortyIndex = U4(b, at, "shorty_idx"), returnIndex = U4(b, at + 4, "return_type_idx");
        uint parameters = U4(b, at + 8, "parameters_off");
        if (shortyIndex >= ss || returnIndex >= ts) Bad("proto index exceeds its table");
        string shorty = Str(b, shortyIndex, ss, so, strings);
        string ret = Type(b, returnIndex, ts, to, ss, so, strings, types); ValidateType(ret, true);
        var args = new List<string>();
        if (parameters != 0) {
            if (parameters < 0x70 || (parameters & 3) != 0) Bad("invalid parameters_off");
            uint count = U4(b, parameters, "parameter count");
            Need(b, (long)parameters + 4, checked(2L * count), "parameter list");
            for (uint p = 0; p < count; p++) {
                ushort ti = U2(b, (long)parameters + 4L + 2L * p, "parameter type");
                if (ti >= ts) Bad("parameter type exceeds type_ids_size");
                string arg = Type(b, ti, ts, to, ss, so, strings, types); ValidateType(arg, false); args.Add(arg);
            }
        }
        var expectedShorty = new StringBuilder(); expectedShorty.Append(Shorty(ret));
        foreach (string arg in args) expectedShorty.Append(Shorty(arg));
        if (!String.Equals(shorty, expectedShorty.ToString(), StringComparison.Ordinal)) Bad("proto shorty mismatch");
        var result = new StringBuilder("("); foreach (string arg in args) result.Append(arg);
        result.Append(')').Append(ret); found = result.ToString(); cache.Add(i, found); return found;
    }

    static string Type(byte[] b, uint i, uint ts, uint to, uint ss, uint so,
        Dictionary<uint,string> strings, Dictionary<uint,string> cache)
    {
        string found; if (cache.TryGetValue(i, out found)) return found;
        if (i >= ts) Bad("invalid type index");
        found = Str(b, U4(b, (long)to + 4L * i, "descriptor_idx"), ss, so, strings);
        cache.Add(i, found); return found;
    }

    static string Str(byte[] b, uint i, uint ss, uint so, Dictionary<uint,string> cache)
    {
        string found; if (cache.TryGetValue(i, out found)) return found;
        if (i >= ss) Bad("invalid string index");
        uint data = U4(b, (long)so + 4L * i, "string_data_off"); if (data < 0x70) Bad("string points into header");
        long at = data; uint declared = Uleb(b, ref at); ulong actual = 0; var text = new StringBuilder();
        for (;;) {
            Need(b, at, 1, "MUTF-8 string"); byte a = b[(int)at++]; if (a == 0) break; uint unit;
            if ((a & 0x80) == 0) unit = a;
            else if ((a & 0xe0) == 0xc0) {
                Need(b, at, 1, "MUTF-8 continuation"); byte c = b[(int)at++];
                if ((c & 0xc0) != 0x80) Bad("invalid MUTF-8 continuation");
                unit = (uint)(((a & 0x1f) << 6) | (c & 0x3f)); if (unit < 0x80 && unit != 0) Bad("overlong MUTF-8");
            } else if ((a & 0xf0) == 0xe0) {
                Need(b, at, 2, "MUTF-8 continuation"); byte c = b[(int)at++], d = b[(int)at++];
                if ((c & 0xc0) != 0x80 || (d & 0xc0) != 0x80) Bad("invalid MUTF-8 continuation");
                unit = (uint)(((a & 15) << 12) | ((c & 63) << 6) | (d & 63)); if (unit < 0x800) Bad("overlong MUTF-8");
            } else { Bad("invalid MUTF-8 leading byte"); return null; }
            text.Append((char)unit); if (++actual > declared) Bad("string exceeds declared UTF-16 length");
        }
        if (actual != declared) Bad("string UTF-16 length mismatch"); found = text.ToString(); cache.Add(i, found); return found;
    }

    static void ValidateType(string d, bool allowVoid)
    {
        if (String.IsNullOrEmpty(d)) Bad("empty type descriptor");
        int p = 0; while (p < d.Length && d[p] == '[') p++; bool array = p != 0;
        if (p >= d.Length) Bad("invalid array descriptor"); char c = d[p];
        if (c == 'L') {
            if (d.Length < p + 3 || d[d.Length - 1] != ';' || d.IndexOf('.', p) >= 0 || d.IndexOf('[', p) >= 0)
                Bad("invalid reference descriptor"); return;
        }
        if (p != d.Length - 1 || "VZBSCIJFD".IndexOf(c) < 0 || (c == 'V' && (!allowVoid || array)))
            Bad("invalid primitive descriptor");
    }
    static char Shorty(string d) { return d[0] == '[' || d[0] == 'L' ? 'L' : d[0]; }
    static uint Uleb(byte[] b, ref long at) {
        ulong v = 0; for (int n = 0; n < 5; n++) { Need(b, at, 1, "ULEB128"); byte c = b[(int)at++];
            v |= ((ulong)(c & 0x7f)) << (7 * n); if ((c & 0x80) == 0) { if (n == 4 && (c & 0xf0) != 0) Bad("ULEB128 overflow"); return (uint)v; } }
        Bad("ULEB128 too long"); return 0;
    }
    static ushort U2(byte[] b, long o, string c) { Need(b,o,2,c); int i=(int)o; return (ushort)(b[i]|(b[i+1]<<8)); }
    static uint U4(byte[] b, long o, string c) { Need(b,o,4,c); int i=(int)o; return (uint)(b[i]|(b[i+1]<<8)|(b[i+2]<<16)|(b[i+3]<<24)); }
    static void Table(byte[] b, uint n, uint o, uint z, string name) {
        if (n == 0) { if (o != 0) Bad("empty " + name + " table has nonzero offset"); return; }
        if (o < 0x70 || (o & 3) != 0) Bad(name + " table has invalid offset"); Need(b,o,checked((long)n*z),name);
    }
    static void Need(byte[] b, long o, long n, string c) { if (b == null || o < 0 || n < 0 || o > b.LongLength - n) Bad(c + " is outside the DEX file"); }
    static void Bad(string message) { throw new InvalidOperationException("Malformed DEX: " + message + "."); }
}
'@
}

$resolvedPaths = [System.Collections.Generic.List[string]]::new()
foreach ($path in $ArtifactPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Artifact does not exist or is not a file: $path"
    }
    $resolvedPaths.Add((Resolve-Path -LiteralPath $path).Path)
}
$resolvedPathArray = $resolvedPaths.ToArray()
[System.Array]::Sort(
    $resolvedPathArray,
    [System.StringComparer]::OrdinalIgnoreCase
)

$allMatches = [System.Collections.Generic.List[string]]::new()
[int]$artifactCount = 0
[int]$dexCount = 0

foreach ($resolvedPath in $resolvedPathArray) {
    $artifactCount++
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)
        $dexEntriesByName = @{}
        $dexEntryNames = [System.Collections.Generic.List[string]]::new()
        foreach ($candidate in $archive.Entries) {
            if ($candidate.FullName -notmatch '(^|/)classes([0-9]+)?\.dex$') {
                continue
            }
            if ($dexEntriesByName.ContainsKey($candidate.FullName)) {
                throw "Archive contains a duplicate DEX entry name: " +
                    "$resolvedPath::$($candidate.FullName)"
            }
            $dexEntriesByName[$candidate.FullName] = $candidate
            $dexEntryNames.Add($candidate.FullName)
        }
        $sortedDexEntryNames = $dexEntryNames.ToArray()
        [System.Array]::Sort(
            $sortedDexEntryNames,
            [System.StringComparer]::Ordinal
        )

        if ($sortedDexEntryNames.Count -eq 0) {
            throw "Archive contains no classes*.dex entries: $resolvedPath"
        }

        foreach ($entryName in $sortedDexEntryNames) {
            $entry = $dexEntriesByName[$entryName]
            if ($entry.Length -le 0 -or $entry.Length -gt [int]::MaxValue) {
                throw "DEX entry has an unsupported size $($entry.Length): " +
                    "$resolvedPath::$($entry.FullName)"
            }

            $stream = $null
            $memory = $null
            try {
                $stream = $entry.Open()
                $memory = [System.IO.MemoryStream]::new(
                    [int]$entry.Length
                )
                $stream.CopyTo($memory)
                if ($memory.Length -ne $entry.Length) {
                    throw "Could not read complete DEX entry: " +
                        "$resolvedPath::$($entry.FullName)"
                }
                $bytes = $memory.ToArray()
            }
            finally {
                if ($null -ne $memory) {
                    $memory.Dispose()
                }
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
            }

            $dexCount++
            $label = "$resolvedPath::$($entry.FullName)"
            foreach ($match in [ZeonWindowDexMethodScanner]::Scan(
                    $bytes,
                    $label
                )) {
                $allMatches.Add($match)
            }
        }
    }
    catch {
        throw "Failed to scan Android artifact '$resolvedPath': $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

$sortedMatches = $allMatches.ToArray()
[System.Array]::Sort($sortedMatches, [System.StringComparer]::Ordinal)

Write-Output "Artifacts scanned: $artifactCount"
Write-Output "DEX files scanned: $dexCount"
if ($sortedMatches.Count -eq 0) {
    Write-Output 'Deprecated Window method references: ABSENT'
    Write-Output 'Verdict: PASS'
    return
}

if ($AllowMatches) {
    Write-Output 'Deprecated Window method references: PRESENT (report-only)'
}
else {
    Write-Output 'Deprecated Window method references: PRESENT'
}
foreach ($match in $sortedMatches) {
    Write-Output $match
}

if ($AllowMatches) {
    Write-Output 'Verdict: FAIL (allowed by -AllowMatches)'
    return
}

Write-Output 'Verdict: FAIL'
throw "Found $($sortedMatches.Count) forbidden android.view.Window method " +
    'reference(s).'
