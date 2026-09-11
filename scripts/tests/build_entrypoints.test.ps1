$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$scriptDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot = Split-Path -Parent $scriptDir
$commonPath = Join-Path $scriptDir "build\common.ps1"
. $commonPath

$powershellFiles = @(
    "build.ps1",
    "build\common.ps1",
    "build_windows_portable.ps1",
    "build_windows_release_folder.ps1",
    "build_windows_installer_exe.ps1",
    "build_windows_installer_msix.ps1",
    "package_windows_installers.ps1",
    "build_android_installation_apks.ps1",
    "build_and_install_android.ps1"
)

foreach ($relativePath in $powershellFiles) {
    $path = Join-Path $scriptDir $relativePath
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True -Condition ($parseErrors.Count -eq 0) -Message "PowerShell parser errors in $relativePath"
}

$help = (& (Join-Path $scriptDir "build.ps1") -ListActions 6>&1 | Out-String)
foreach ($action in @(
    "windows-folder",
    "windows-portable",
    "windows-exe",
    "windows-msix",
    "android-apk",
    "android-apks",
    "android-debug-install"
)) {
    Assert-True -Condition $help.Contains($action) -Message "Build action is missing from help: $action"
}

$testRoot = Join-Path "Z:\Zeon-Envelope\Temp" ("zeon-build-script-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $sourceFile = Join-Path $testRoot "source.apk"
    Set-Content -LiteralPath $sourceFile -Value "fixture" -NoNewline
    $publishedPath = Publish-ZeonFile `
        -RepoRoot $testRoot `
        -Platform "android" `
        -SourcePath $sourceFile `
        -DestinationName "ZEON-test.apk"
    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $testRoot "out\installers"))
    Assert-True -Condition $publishedPath.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase) -Message "Artifact escaped out/installers"

    $outsideWasRejected = $false
    try {
        Assert-ZeonInstallerPath -RepoRoot $testRoot -Path (Join-Path $testRoot "outside.apk") | Out-Null
    }
    catch {
        $outsideWasRejected = $true
    }
    Assert-True -Condition $outsideWasRejected -Message "Path guard accepted an artifact outside out/installers"
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $allowedPrefix = [System.IO.Path]::GetFullPath("Z:\Zeon-Envelope\Temp").TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected test directory: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

$appleBuild = Get-Content -LiteralPath (Join-Path $scriptDir "apple\build.sh") -Raw
Assert-True -Condition $appleBuild.Contains("out/installers") -Message "Apple build does not publish to out/installers"
Assert-True -Condition (-not $appleBuild.Contains("out/apple")) -Message "Apple build still publishes to out/apple"
Assert-True -Condition $appleBuild.Contains("build_and_install_ios_device") -Message "Apple entrypoint is missing iOS device installation"

$windowsBuilder = Get-Content -LiteralPath (Join-Path $scriptDir "build_and_install_windows.ps1") -Raw
Assert-True -Condition $windowsBuilder.Contains('$flutterExitCode') -Message "Windows Flutter version check must preserve the native exit code"

$windowsPackager = Get-Content -LiteralPath (Join-Path $scriptDir "package_windows_installers.ps1") -Raw
Assert-True -Condition $windowsPackager.Contains('Z:\Zeon-Envelope\Temp\wz') -Message "Canonical Windows workspace must use ZEON Temp"
Assert-True -Condition $windowsPackager.Contains('[System.IO.Path]::GetTempPath()') -Message "Windows packaging needs a portable CI temp fallback"
Assert-True -Condition (-not $windowsPackager.Contains('cmd /c')) -Message "Windows packaging must invoke robocopy directly"

$commonBuild = Get-Content -LiteralPath $commonPath -Raw
Assert-True -Condition $commonBuild.Contains('Get-Command "flutter"') -Message "Pinned Flutter resolver must accept an exact SDK already in PATH"

Write-Host "Build entrypoint tests passed."
