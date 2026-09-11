Set-StrictMode -Version Latest

function Get-ZeonRequiredFlutterVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $pubspecPath = Join-Path $RepoRoot "pubspec.yaml"
    $line = Get-Content -LiteralPath $pubspecPath |
        Select-String -Pattern "^\s*flutter:\s*\^?([0-9]+\.[0-9]+\.[0-9]+)\s*$" |
        Select-Object -First 1
    if (-not $line) {
        throw "Failed to detect required Flutter version from $pubspecPath"
    }
    return $line.Matches[0].Groups[1].Value
}

function Invoke-ZeonFlutterVersionMachine {
    param([Parameter(Mandatory = $true)][string]$FlutterPath)

    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5 turns native stderr into ErrorRecord objects when
        # ErrorActionPreference=Stop. Flutter writes first-run progress there.
        $ErrorActionPreference = "Continue"
        $output = & $FlutterPath --version --machine 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -or -not $output) {
        return $null
    }
    return ($output | Out-String).Trim()
}

function Use-ZeonPinnedFlutter {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $requiredVersion = Get-ZeonRequiredFlutterVersion -RepoRoot $RepoRoot
    $explicitFlutterRoot = $env:ZEON_FLUTTER_ROOT

    $pathFlutter = Get-Command "flutter" -ErrorAction SilentlyContinue
    if ($pathFlutter) {
        $versionOutput = Invoke-ZeonFlutterVersionMachine -FlutterPath $pathFlutter.Source
        if ($versionOutput -and (($versionOutput | ConvertFrom-Json).frameworkVersion -eq $requiredVersion)) {
            Write-Host "Using pinned Flutter $requiredVersion from PATH: $($pathFlutter.Source)"
            return $pathFlutter.Source
        }
    }

    $repoFullPath = [System.IO.Path]::GetFullPath($RepoRoot)
    $canonicalProjectsRoot = [System.IO.Path]::GetFullPath("Z:\Zeon-Envelope\Projects")
    $canonicalPrefix = $canonicalProjectsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $isCanonicalWorkspace = $repoFullPath.StartsWith($canonicalPrefix, [System.StringComparison]::OrdinalIgnoreCase)

    if ($isCanonicalWorkspace) {
        $envelopeRoot = Split-Path -Parent $canonicalProjectsRoot
        $sharedFlutterRoot = Join-Path $envelopeRoot "SDK\Flutter"
        $cachedFlutterRoot = Join-Path $envelopeRoot "Caches\Flutter\$requiredVersion"
    }
    else {
        $sharedFlutterRoot = $null
        $cachedFlutterRoot = $null
    }

    $candidates = @($explicitFlutterRoot, $cachedFlutterRoot, $sharedFlutterRoot) |
        Where-Object { $_ }
    foreach ($candidate in $candidates) {
        $flutterPath = Join-Path $candidate "bin\flutter.bat"
        if (-not (Test-Path -LiteralPath $flutterPath -PathType Leaf)) {
            continue
        }
        $versionOutput = Invoke-ZeonFlutterVersionMachine -FlutterPath $flutterPath
        if ($versionOutput -and (($versionOutput | ConvertFrom-Json).frameworkVersion -eq $requiredVersion)) {
            $env:PATH = (Join-Path $candidate "bin") + [System.IO.Path]::PathSeparator + $env:PATH
            Write-Host "Using pinned Flutter $requiredVersion from: $candidate"
            return $flutterPath
        }
    }

    if ($explicitFlutterRoot) {
        throw "ZEON_FLUTTER_ROOT does not contain the required Flutter ${requiredVersion}: $explicitFlutterRoot"
    }
    if (-not $isCanonicalWorkspace) {
        throw "Flutter $requiredVersion is required. Install it in PATH or set ZEON_FLUTTER_ROOT to that SDK."
    }
    if (Test-Path -LiteralPath $cachedFlutterRoot) {
        throw "Pinned Flutter cache exists but is incomplete or has the wrong version: $cachedFlutterRoot"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sharedFlutterRoot ".git"))) {
        throw "Flutter $requiredVersion is unavailable. Expected a source repository at: $sharedFlutterRoot"
    }

    $tag = & git -C $sharedFlutterRoot tag -l $requiredVersion
    if ($LASTEXITCODE -ne 0 -or $tag -ne $requiredVersion) {
        throw "Flutter tag $requiredVersion is unavailable in $sharedFlutterRoot. Fetch it before building."
    }

    $cacheParent = Split-Path -Parent $cachedFlutterRoot
    New-Item -ItemType Directory -Force -Path $cacheParent | Out-Null
    Write-Host "Preparing pinned Flutter $requiredVersion in build cache: $cachedFlutterRoot"
    & git -C $sharedFlutterRoot worktree add --detach $cachedFlutterRoot "refs/tags/$requiredVersion"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prepare Flutter $requiredVersion at $cachedFlutterRoot"
    }

    $cachedFlutterPath = Join-Path $cachedFlutterRoot "bin\flutter.bat"
    if (-not (Test-Path -LiteralPath $cachedFlutterPath -PathType Leaf)) {
        throw "Pinned Flutter executable was not created: $cachedFlutterPath"
    }
    $env:PATH = (Join-Path $cachedFlutterRoot "bin") + [System.IO.Path]::PathSeparator + $env:PATH
    Write-Host "Using pinned Flutter $requiredVersion from: $cachedFlutterRoot"
    return $cachedFlutterPath
}

function Get-ZeonAppVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $pubspecPath = Join-Path $RepoRoot "pubspec.yaml"
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        throw "pubspec.yaml not found: $pubspecPath"
    }

    $line = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*(.+)$" | Select-Object -First 1
    if (-not $line) {
        throw "Could not find 'version' in $pubspecPath"
    }

    return $line.Matches[0].Groups[1].Value.Trim()
}

function ConvertTo-ZeonArtifactVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    return ($Version -replace '[<>:"/\\|?*]', '-')
}

function Get-ZeonInstallersRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "out\installers"))
}

function Assert-ZeonInstallerPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $installersRoot = Get-ZeonInstallersRoot -RepoRoot $RepoRoot
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $installersRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Final build artifacts must be under '$installersRoot'. Refusing path: $resolvedPath"
    }

    return $resolvedPath
}

function Get-ZeonInstallerPlatformDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet("android", "win", "ios", "macos")][string]$Platform
    )

    $directory = Join-Path (Get-ZeonInstallersRoot -RepoRoot $RepoRoot) $Platform
    $directory = Assert-ZeonInstallerPath -RepoRoot $RepoRoot -Path $directory
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    return $directory
}

function Assert-ZeonArtifactName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([System.IO.Path]::GetFileName($Name) -ne $Name -or $Name -in @(".", "..")) {
        throw "Artifact name must be a single file or directory name: $Name"
    }
}

function Publish-ZeonFile {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet("android", "win", "ios", "macos")][string]$Platform,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationName
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Build artifact was not found: $SourcePath"
    }
    Assert-ZeonArtifactName -Name $DestinationName

    $platformDirectory = Get-ZeonInstallerPlatformDirectory -RepoRoot $RepoRoot -Platform $Platform
    $destinationPath = Assert-ZeonInstallerPath -RepoRoot $RepoRoot -Path (Join-Path $platformDirectory $DestinationName)
    $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($sourceFullPath, $destinationPath)) {
        Copy-Item -LiteralPath $sourceFullPath -Destination $destinationPath -Force
    }

    $hash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
    Write-Host "Published: $destinationPath"
    Write-Host "SHA-256:  $hash"
    return $destinationPath
}

function Publish-ZeonDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet("android", "win", "ios", "macos")][string]$Platform,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationName
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Build directory was not found: $SourcePath"
    }
    Assert-ZeonArtifactName -Name $DestinationName

    $platformDirectory = Get-ZeonInstallerPlatformDirectory -RepoRoot $RepoRoot -Platform $Platform
    $destinationPath = Assert-ZeonInstallerPath -RepoRoot $RepoRoot -Path (Join-Path $platformDirectory $DestinationName)
    if (Test-Path -LiteralPath $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Recurse -Force
    }
    Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Recurse -Force
    Write-Host "Published directory: $destinationPath"
    return $destinationPath
}
