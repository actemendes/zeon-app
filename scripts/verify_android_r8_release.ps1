param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigurationPath,

    [Parameter(Mandatory = $true)]
    [string]$MappingPath,

    [Parameter(Mandatory = $true)]
    [string]$UsagePath,

    [Parameter(Mandatory = $true)]
    [string]$ResourcesPath,

    [string]$BuildFile = "android/app/build.gradle"
)

$ErrorActionPreference = "Stop"

function Read-RequiredFile {
    param([string]$Path, [string]$Description)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Description is not a file: $($resolved.Path)"
    }
    $item = Get-Item -LiteralPath $resolved.Path
    if ($item.Length -eq 0) {
        throw "$Description is empty: $($resolved.Path)"
    }
    return @{
        Path = $resolved.Path
        Text = Get-Content -LiteralPath $resolved.Path -Raw
        Length = $item.Length
    }
}

$configuration = Read-RequiredFile $ConfigurationPath "R8 configuration"
$mapping = Read-RequiredFile $MappingPath "R8 mapping"
$usage = Read-RequiredFile $UsagePath "R8 usage report"
$resources = Read-RequiredFile $ResourcesPath "resource shrinker report"
$build = Read-RequiredFile $BuildFile "Android app build file"

$disabledOptions = @(
    "-dontoptimize",
    "-dontshrink",
    "-dontobfuscate"
) | Where-Object { $configuration.Text -match "(?m)^\s*$([regex]::Escape($_))(?:\s|$)" }

$unboundedKeepPatterns = @(
    "(?m)^\s*-keep(?:,[^\s]+)*\s+class\s+\*\*\s*\{\s*\*\s*;\s*\}",
    "(?m)^\s*-keep\s+\*\*",
    "(?m)^\s*-keepclassmembers\s+class\s+\*\*\s*\{\s*\*\s*;\s*\}"
)
$unboundedKeepRules = @($unboundedKeepPatterns | Where-Object {
    $configuration.Text -match $_
})

$optimizedDefaults = $configuration.Text -match "proguard-android-optimize\.txt"
$explicitMinify = $build.Text -match "(?m)^\s*minifyEnabled\s+true\s*$"
$explicitResourceShrink = $build.Text -match "(?m)^\s*shrinkResources\s+true\s*$"
$customRulesDeclared = $build.Text -match "proguardFile\s+['""]proguard-rules\.pro['""]"
$r8Compiler = if ($mapping.Text -match "(?m)^# compiler: R8$") { "R8" } else { "unknown" }
$r8Version = if ($mapping.Text -match "(?m)^# compiler_version: ([^\r\n]+)$") {
    $Matches[1]
} else {
    "unknown"
}

$result = [ordered]@{
    compiler = $r8Compiler
    r8_version = $r8Version
    minify_explicit = $explicitMinify
    shrink_resources_explicit = $explicitResourceShrink
    optimized_default_configuration = $optimizedDefaults
    custom_rules_declared = $customRulesDeclared
    disabled_options = @($disabledOptions)
    unbounded_keep_rule_patterns = @($unboundedKeepRules)
    mapping_bytes = $mapping.Length
    usage_bytes = $usage.Length
    resources_report_bytes = $resources.Length
    full_mode_disabled_property_present =
        (Get-Content -LiteralPath "android/gradle.properties" -Raw) -match
        "(?m)^\s*android\.enableR8\.fullMode\s*=\s*false\s*$"
}

$result | ConvertTo-Json -Depth 4

if ($r8Compiler -ne "R8") {
    throw "Release mapping was not produced by R8."
}
if (-not $explicitMinify -or -not $explicitResourceShrink -or -not $optimizedDefaults) {
    throw "Release minification, resource shrinking, or optimized defaults are not proven."
}
if ($disabledOptions.Count -ne 0) {
    throw "R8 optimization is disabled by: $($disabledOptions -join ', ')"
}
if ($unboundedKeepRules.Count -ne 0) {
    throw "Unbounded keep rules were detected in the merged release configuration."
}
if ($result.full_mode_disabled_property_present) {
    throw "R8 full mode is explicitly disabled."
}
