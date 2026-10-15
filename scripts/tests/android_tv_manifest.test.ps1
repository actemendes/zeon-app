[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$EvidenceDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$androidNamespace = 'http://schemas.android.com/apk/res/android'
$manifestPath = Join-Path $repoRoot 'build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml'
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$results = @()
Push-Location (Join-Path $repoRoot 'android')
try {
    # Exercise the real manifest merger, including sequential-build isolation.
    foreach ($case in @(
        @{ Name = 'default-before'; Property = $null; Required = 'false' },
        @{ Name = 'tv'; Property = '-PzeonTvOnly=true'; Required = 'true' },
        @{ Name = 'default-after'; Property = $null; Required = 'false' }
    )) {
        $gradleArguments = @(':app:processReleaseMainManifest', '--console=plain', '-Dorg.gradle.workers.max=1')
        if ($case.Property) { $gradleArguments += $case.Property }
        & .\gradlew.bat @gradleArguments *> (Join-Path $EvidenceDirectory ($case.Name + '.log'))
        if ($LASTEXITCODE -ne 0) { throw "Manifest merge failed: $($case.Name)" }
        [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
        foreach ($feature in @(
            @{ Name = 'android.software.leanback'; Required = $case.Required },
            @{ Name = 'android.hardware.touchscreen'; Required = 'false' },
            @{ Name = 'android.hardware.camera'; Required = 'false' }
        )) {
            $nodes = @($manifest.manifest.'uses-feature' | Where-Object { $_.GetAttribute('name', $androidNamespace) -eq $feature.Name })
            if ($nodes.Count -ne 1 -or $nodes[0].GetAttribute('required', $androidNamespace) -ne $feature.Required) {
                throw "Wrong merged feature $($feature.Name) in $($case.Name)"
            }
        }
        if (-not $manifest.manifest.application.GetAttribute('banner', $androidNamespace)) { throw 'TV banner missing' }
        $tvLauncher = @($manifest.SelectNodes('//category') | Where-Object { $_.GetAttribute('name', $androidNamespace) -eq 'android.intent.category.LEANBACK_LAUNCHER' })
        if ($tvLauncher.Count -ne 1) { throw 'TV launcher missing or duplicated' }
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $EvidenceDirectory ($case.Name + '.xml'))
        $results += @{ case = $case.Name; status = 'PASS'; leanback_required = $case.Required }
    }
    & .\gradlew.bat :app:processReleaseMainManifest '-PzeonTvOnly=invalid' --console=plain *> (Join-Path $EvidenceDirectory 'invalid.log')
    if ($LASTEXITCODE -eq 0 -or -not (Select-String -LiteralPath (Join-Path $EvidenceDirectory 'invalid.log') -SimpleMatch 'zeonTvOnly must be true or false')) {
        throw 'Invalid TV build property did not fail closed'
    }
    $results += @{ case = 'invalid'; status = 'PASS'; rejected = $true }
    @{ status = 'PASS'; cases = $results } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'manifest-result.json') -Encoding utf8
    Write-Host 'Android TV manifest merger tests passed.'
}
finally { Pop-Location }
