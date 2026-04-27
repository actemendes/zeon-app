$ErrorActionPreference = "Stop"

function Get-RequiredFlutterVersion {
  $pubspecPath = Join-Path $PSScriptRoot "..\\pubspec.yaml"
  $line = Get-Content $pubspecPath | Select-String -Pattern "^\s*flutter:\s*\^?([0-9]+\.[0-9]+\.[0-9]+)\s*$" | Select-Object -First 1
  if (-not $line) {
    throw "Failed to detect required Flutter version from pubspec.yaml"
  }
  return $line.Matches[0].Groups[1].Value
}

function Assert-FlutterVersion {
  $requiredVersion = Get-RequiredFlutterVersion
  $versionOutput = flutter --version --machine 2>$null
  if (-not $versionOutput) {
    throw "Flutter is not available in PATH"
  }
  $actualVersion = ($versionOutput | ConvertFrom-Json).frameworkVersion
  if (-not $actualVersion.StartsWith($requiredVersion)) {
    throw "Flutter version mismatch. Required $requiredVersion.x, got $actualVersion"
  }
  Write-Host "Flutter version OK: $actualVersion"
}

$coreProbe = Join-Path $PSScriptRoot "..\\hiddify-core\\v2\\config\\builder.go"
if (-not (Test-Path $coreProbe)) {
  throw "hiddify-core directory is missing. Make sure repository contains vendored hiddify-core."
}
Write-Host "Vendored hiddify-core found."

Write-Host "Validate Flutter version..."
Assert-FlutterVersion

Write-Host "Resolve dependencies with lockfile..."
flutter pub get --enforce-lockfile

Write-Host "Bootstrap completed."
