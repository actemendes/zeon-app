param(
    [Parameter(Mandatory = $true)]
    [string]$MappingPath,

    [Parameter(Mandatory = $true)]
    [string]$FilePickerSource,

    [string]$DecoderSource,

    [ValidateSet("unsafe", "safe")]
    [string]$ExpectedState = "safe"
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$Description
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Description is not a file: $($resolved.Path)"
    }
    return $resolved.Path
}

$mapping = Resolve-ExistingFile -Path $MappingPath -Description "R8 mapping"
$source = Resolve-ExistingFile -Path $FilePickerSource -Description "file_picker FileUtils source"

$mappingText = Get-Content -LiteralPath $mapping -Raw
$sourceText = Get-Content -LiteralPath $source -Raw

$classMapped = $mappingText -match '(?m)^com\.google\.android\.gms\.internal\.mlkit_vision_barcode\.zzpg -> r2\.u5:$'
$methodMapped = $mappingText -match '(?m)com\.mr\.flutter\.plugin\.filepicker\.FileUtils\.compressImage\(android\.net\.Uri,int,android\.content\.Context\)(?::\d+(?::\d+)?)? -> a$'

if (-not $classMapped -or -not $methodMapped) {
    throw "The release mapping does not prove that r2.u5.a contains file_picker FileUtils.compressImage()."
}

$decoderText = if ($DecoderSource) {
    $decoder = Resolve-ExistingFile -Path $DecoderSource -Description "sampled bitmap decoder source"
    Get-Content -LiteralPath $decoder -Raw
} else {
    $sourceText
}

$hasBoundsPass = $decoderText -match 'inJustDecodeBounds\s*=\s*true'
$hasSampleSize = $decoderText -match 'inSampleSize\s*='
$unsafeOneArgumentDecode = $sourceText -match 'BitmapFactory\.decodeStream\s*\(\s*imageStream\s*\)'
$safeOptionsDecode = $decoderText -match 'BitmapFactory\.decodeStream\s*\([^,]+,\s*null\s*,\s*[A-Za-z][A-Za-z0-9_]*\s*\)'

$actualState = if ($hasBoundsPass -and $hasSampleSize -and $safeOptionsDecode -and -not $unsafeOneArgumentDecode) {
    "safe"
} else {
    "unsafe"
}

$result = [ordered]@{
    mapping = $mapping
    source = $source
    obfuscated_class = "r2.u5"
    obfuscated_method = "r2.u5.a"
    source_class = "com.mr.flutter.plugin.filepicker.FileUtils"
    source_method = "compressImage(android.net.Uri,int,android.content.Context)"
    bounds_pass = $hasBoundsPass
    sample_size = $hasSampleSize
    safe_options_decode = $safeOptionsDecode
    unsafe_one_argument_decode = $unsafeOneArgumentDecode
    actual_state = $actualState
    expected_state = $ExpectedState
}

$result | ConvertTo-Json

if ($actualState -ne $ExpectedState) {
    throw "Bitmap decode state was '$actualState'; expected '$ExpectedState'."
}
