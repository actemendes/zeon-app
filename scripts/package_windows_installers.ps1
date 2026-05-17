[CmdletBinding()]
param(
    [ValidateSet("exe", "msix", "all")]
    [string]$Target = "all",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [string]$CertificatePassword = "zeon-local",

    [switch]$UseExistingCertificateOnly,

    [switch]$NoIsolatedWorkspace,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Test-PathHasFlutterBlockedCharacters {
    param([Parameter(Mandatory = $true)][string]$PathToCheck)

    return [regex]::IsMatch($PathToCheck, "[\'#!$^&*=|,;<>?]")
}

function New-CleanPathJunction {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $junctionRoot = Join-Path $env:TEMP "zeon_windows_build"
    New-Item -ItemType Directory -Force -Path $junctionRoot | Out-Null

    $junctionPath = Join-Path $junctionRoot ("source_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Junction -Path $junctionPath -Target $RepoRoot | Out-Null

    return $junctionPath
}

function Ensure-Fastforge {
    $pubBin = Join-Path $env:LOCALAPPDATA "Pub\Cache\bin"
    if ((Test-Path -LiteralPath $pubBin) -and ($env:PATH -notlike "*$pubBin*")) {
        $env:PATH = "$pubBin;$env:PATH"
    }

    if (Get-Command fastforge -ErrorAction SilentlyContinue) {
        return
    }

    Assert-Command "dart"
    Write-Host "fastforge not found. Installing via dart pub global activate..."
    & dart pub global activate fastforge
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install fastforge."
    }

    if ((Test-Path -LiteralPath $pubBin) -and ($env:PATH -notlike "*$pubBin*")) {
        $env:PATH = "$pubBin;$env:PATH"
    }

    Assert-Command "fastforge"
}

function Ensure-InnoSetup {
    param([switch]$SkipInstall)

    $knownIscc = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    )

    foreach ($path in $knownIscc) {
        if (Test-Path -LiteralPath $path) {
            $dir = Split-Path -Parent $path
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
            return $path
        }
    }

    $isccCmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($isccCmd) {
        return $isccCmd.Source
    }

    if ($SkipInstall) {
        throw "Inno Setup 6 is required for target 'exe' but was not found."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Inno Setup 6 is required for target 'exe'. winget is not available for auto-install."
    }

    Write-Host "Inno Setup 6 not found. Installing via winget..."
    & winget install --id JRSoftware.InnoSetup -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install Inno Setup 6."
    }

    foreach ($path in $knownIscc) {
        if (Test-Path -LiteralPath $path) {
            $dir = Split-Path -Parent $path
            if ($env:PATH -notlike "*$dir*") {
                $env:PATH = "$dir;$env:PATH"
            }
            return $path
        }
    }

    $isccCmd = Get-Command iscc -ErrorAction SilentlyContinue
    if (-not $isccCmd) {
        throw "Inno Setup 6 installation completed but ISCC.exe was not found in PATH."
    }
    return $isccCmd.Source
}

function Get-PubspecVersion {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $pubspecPath = Join-Path $WorkingRoot "pubspec.yaml"
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        throw "pubspec.yaml not found: $pubspecPath"
    }

    $line = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*(.+)$" | Select-Object -First 1
    if (-not $line) {
        throw "Could not find 'version' in $pubspecPath"
    }

    return $line.Matches[0].Groups[1].Value.Trim()
}

function Convert-PubspecVersionToMsix {
    param([Parameter(Mandatory = $true)][string]$PubspecVersion)

    $versionPattern = '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-[0-9A-Za-z\.-]+)?(?:\+(?<build>\d+))?$'
    $match = [regex]::Match($PubspecVersion, $versionPattern)
    if (-not $match.Success) {
        throw "Unsupported pubspec version format '$PubspecVersion'. Expected semantic version like '1.2.3' or '1.2.3+45'."
    }

    $major = [int]$match.Groups["major"].Value
    $minor = [int]$match.Groups["minor"].Value
    $patch = [int]$match.Groups["patch"].Value
    $build = 0
    if ($match.Groups["build"].Success) {
        $build = [int]$match.Groups["build"].Value
    }

    foreach ($value in @($major, $minor, $patch, $build)) {
        if ($value -lt 0 -or $value -gt 65535) {
            throw "MSIX version segment '$value' is out of range (0..65535). pubspec version: $PubspecVersion"
        }
    }

    return "$major.$minor.$patch.$build"
}

function Sync-MsixVersionWithPubspec {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $configPath = Join-Path $WorkingRoot "windows\packaging\msix\make_config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "MSIX config was not found: $configPath"
    }

    $pubspecVersion = Get-PubspecVersion -WorkingRoot $WorkingRoot
    $msixVersion = Convert-PubspecVersionToMsix -PubspecVersion $pubspecVersion
    $currentMsixVersion = Get-YamlScalar -Path $configPath -Key "msix_version"

    if ($currentMsixVersion -ne $msixVersion) {
        Set-YamlScalar -Path $configPath -Key "msix_version" -Value $msixVersion
        Write-Host "Synced MSIX version from pubspec: $pubspecVersion -> $msixVersion"
    }
}

function Build-WindowsRelease {
    param(
        [Parameter(Mandatory = $true)][string]$BuildTarget,
        [string]$SentryDsn
    )

    $args = @("build", "windows", "--release", "--target", $BuildTarget)
    if ($SentryDsn) {
        $args += @("--dart-define", "sentry_dsn=$SentryDsn")
    }

    Write-Host ("Running: flutter " + ($args -join " "))
    & flutter @args
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows failed."
    }
}

function Build-ExeInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingRoot,
        [Parameter(Mandatory = $true)][string]$IsccPath
    )

    $configPath = Join-Path $WorkingRoot "windows\packaging\exe\make_config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "EXE packaging config not found: $configPath"
    }

    $appId = Get-YamlScalar -Path $configPath -Key "app_id"
    $publisher = Get-YamlScalar -Path $configPath -Key "publisher"
    $publisherUrl = Get-YamlScalar -Path $configPath -Key "publisher_url"
    $displayName = Get-YamlScalar -Path $configPath -Key "display_name"
    $installDirName = Get-YamlScalar -Path $configPath -Key "install_dir_name"
    $setupIconFile = Get-YamlScalar -Path $configPath -Key "setup_icon_file"

    if (-not $appId) { $appId = [guid]::NewGuid().ToString() }
    if (-not $publisher) { $publisher = "ZEON" }
    if (-not $publisherUrl) { $publisherUrl = "https://github.com/actemendes/zeon-app" }
    if (-not $displayName) { $displayName = "ZEON" }
    if (-not $installDirName) { $installDirName = "{autopf64}\ZEON" }
    if (-not $setupIconFile) { $setupIconFile = "windows\runner\resources\app_icon.ico" }

    $releaseDir = Join-Path $WorkingRoot "build\windows\x64\runner\Release"
    if (-not (Test-Path -LiteralPath $releaseDir)) {
        throw "Windows release output directory not found: $releaseDir"
    }

    $exeName = "ZEON.exe"
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDir $exeName))) {
        $foundExe = Get-ChildItem -Path $releaseDir -Filter "*.exe" | Where-Object { $_.Name -notmatch "Cli\.exe$|^unins\d+\.exe$" } | Select-Object -First 1
        if (-not $foundExe) {
            throw "Main application .exe was not found in $releaseDir"
        }
        $exeName = $foundExe.Name
    }

    $versionRaw = Get-PubspecVersion -WorkingRoot $WorkingRoot
    $version = $versionRaw
    if ($version.Contains("+")) {
        $version = $version.Split("+")[0]
    }

    $distDir = Join-Path $WorkingRoot "dist\zeon"
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    $issPath = Join-Path $WorkingRoot "build\windows\zeon_installer.iss"

    $releaseDirForIss = $releaseDir -replace '/', '\'
    $iconForIss = (Join-Path $WorkingRoot $setupIconFile) -replace '/', '\'
    $distDirForIss = $distDir -replace '/', '\'

    $iss = @"
[Setup]
AppId=${appId}
AppName=${displayName}
AppVersion=${version}
AppPublisher=${publisher}
AppPublisherURL=${publisherUrl}
AppSupportURL=${publisherUrl}
AppUpdatesURL=${publisherUrl}
DefaultDirName=${installDirName}
DisableProgramGroupPage=yes
OutputDir=${distDirForIss}
OutputBaseFilename=ZEON-Windows-Setup-x64
Compression=lzma
SolidCompression=yes
SetupIconFile=${iconForIss}
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "${releaseDirForIss}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\${displayName}"; Filename: "{app}\${exeName}"
Name: "{autodesktop}\${displayName}"; Filename: "{app}\${exeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\${exeName}"; Description: "{cm:LaunchProgram,${displayName}}"; Flags: nowait postinstall skipifsilent
"@

    Set-Content -LiteralPath $issPath -Value $iss -NoNewline

    Write-Host ("Running: " + $IsccPath + " " + $issPath)
    & $IsccPath $issPath
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compiler failed."
    }
}

function New-IsolatedWorkspace {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $workspaceRoot = "C:\wz"
    New-Item -ItemType Directory -Force -Path $workspaceRoot | Out-Null
    $workspace = Join-Path $workspaceRoot ("p" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null

    $excludeDirs = @(
        ".git",
        ".dart_tool",
        "build",
        "dist",
        "out",
        ".idea",
        ".vscode",
        "windows\flutter\ephemeral"
    )

    $excludeArgs = @()
    foreach ($dir in $excludeDirs) {
        $excludeArgs += '/XD "{0}"' -f (Join-Path $RepoRoot $dir)
    }

    $command = 'robocopy "{0}" "{1}" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP {2}' -f $RepoRoot, $workspace, ($excludeArgs -join " ")
    cmd /c $command | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "Failed to create isolated workspace via robocopy. Exit code: $LASTEXITCODE"
    }

    return $workspace
}

function Set-YamlScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value,
        [switch]$QuoteValue
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $encodedValue = $Value
    if ($QuoteValue) {
        $encodedValue = '"' + ($Value -replace '"', '\"') + '"'
    }

    $pattern = "(?m)^" + [regex]::Escape($Key) + ":\s*.*$"
    $replacement = "${Key}: $encodedValue"

    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
    }
    else {
        if (-not $content.EndsWith("`n")) {
            $content += "`r`n"
        }
        $content += "$replacement`r`n"
    }

    Set-Content -LiteralPath $Path -Value $content -NoNewline
}

function Get-YamlScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $line = Select-String -Path $Path -Pattern ("^\s*" + [regex]::Escape($Key) + ":\s*(.*)$") | Select-Object -First 1
    if (-not $line) {
        return ""
    }

    $raw = $line.Matches[0].Groups[1].Value.Trim()
    if ($raw.StartsWith('"') -and $raw.EndsWith('"') -and $raw.Length -ge 2) {
        return $raw.Substring(1, $raw.Length - 2)
    }
    return $raw
}

function Ensure-MsixCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingRoot,
        [Parameter(Mandatory = $true)][string]$Password,
        [switch]$UseExistingOnly
    )

    $configPath = Join-Path $WorkingRoot "windows\packaging\msix\make_config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "MSIX config was not found: $configPath"
    }

    $certRelative = Get-YamlScalar -Path $configPath -Key "certificate_path"
    if (-not $certRelative) {
        throw "Field 'certificate_path' is empty in $configPath"
    }

    $certPath = Join-Path $WorkingRoot $certRelative
    if (-not (Test-Path -LiteralPath $certPath)) {
        if ($UseExistingOnly) {
            throw "MSIX certificate was not found: $certPath"
        }

        $publisher = Get-YamlScalar -Path $configPath -Key "publisher"
        if (-not $publisher) {
            $publisher = "CN=ZEON"
            Set-YamlScalar -Path $configPath -Key "publisher" -Value $publisher
        }

        Write-Host "MSIX certificate not found. Generating self-signed cert for $publisher ..."
        $cert = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $publisher `
            -FriendlyName "ZEON Local MSIX Signing" `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -KeyExportPolicy Exportable `
            -KeyUsage DigitalSignature `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -NotAfter (Get-Date).AddYears(3)

        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $certPath -Password $securePassword | Out-Null
    }

    Set-YamlScalar -Path $configPath -Key "certificate_password" -Value $Password -QuoteValue
}

function Patch-FlutterSecureStorageWindowsPlugin {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $pluginLink = Join-Path $WorkingRoot "windows\flutter\ephemeral\.plugin_symlinks\flutter_secure_storage_windows"
    if (-not (Test-Path -LiteralPath $pluginLink)) {
        throw "Plugin symlink not found: $pluginLink. Run 'flutter pub get' first."
    }

    $pluginItem = Get-Item -LiteralPath $pluginLink
    if (-not $pluginItem.Target) {
        throw "Plugin symlink target is empty: $pluginLink"
    }

    $pluginTarget = $pluginItem.Target
    if ($pluginTarget -is [Array]) {
        $pluginTarget = $pluginTarget[0]
    }

    $cppPath = Join-Path $pluginTarget "windows\flutter_secure_storage_windows_plugin.cpp"
    if (-not (Test-Path -LiteralPath $cppPath)) {
        throw "Plugin source file not found: $cppPath"
    }

    $content = Get-Content -LiteralPath $cppPath -Raw
    $hasLegacyAtlTokens = $content -match "CA2W|CW2A|atlstr\.h|\.m_psz"
    $hasHelperFunctions = ($content -match "std::wstring\s+Utf8ToWide\s*\(") -and ($content -match "std::string\s+WideToUtf8\s*\(")
    $usesHelperCalls = $content -match "Utf8ToWide|WideToUtf8"

    if (-not $hasLegacyAtlTokens -and ($hasHelperFunctions -or -not $usesHelperCalls)) {
        Write-Host "flutter_secure_storage_windows is already ATL-free."
        return
    }

    $updated = $content
    $updated = $updated.Replace("#include <atlstr.h>`r`n", "")
    $updated = $updated.Replace("#include <atlstr.h>`n", "")

    if (-not $hasHelperFunctions) {
        $anchorPattern = "(const int ELEMENT_PREFERENCES_KEY_PREFIX_LENGTH = \(sizeof SECURE_STORAGE_KEY_PREFIX\) - 1;)"
        if ($updated -notmatch $anchorPattern) {
            throw "Could not find insertion anchor for helper functions in: $cppPath"
        }

        $helperBlock = @"

  std::wstring Utf8ToWide(const std::string& value) {
      if (value.empty()) {
          return std::wstring();
      }
      const int required = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
      if (required <= 0) {
          return std::wstring();
      }
      std::wstring wide(static_cast<size_t>(required), L'\0');
      MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, wide.data(), required);
      if (!wide.empty() && wide.back() == L'\0') {
          wide.pop_back();
      }
      return wide;
  }

  std::string WideToUtf8(const std::wstring& value) {
      if (value.empty()) {
          return std::string();
      }
      const int required = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
      if (required <= 0) {
          return std::string();
      }
      std::string utf8(static_cast<size_t>(required), '\0');
      WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), required, nullptr, nullptr);
      if (!utf8.empty() && utf8.back() == '\0') {
          utf8.pop_back();
      }
      return utf8;
  }
"@
        $updated = [regex]::Replace($updated, $anchorPattern, "`$1$helperBlock")
    }

    $updated = $updated.Replace("CREDENTIAL_FILTER.m_psz", "CREDENTIAL_FILTER.c_str()")
    $updated = $updated.Replace("const CA2W CREDENTIAL_FILTER((ELEMENT_PREFERENCES_KEY_PREFIX + '*').c_str());", "const std::wstring CREDENTIAL_FILTER = Utf8ToWide(ELEMENT_PREFERENCES_KEY_PREFIX + '*');")
    $updated = [regex]::Replace($updated, "const\s+std::wstring\s+CREDENTIAL_FILTER\s*=.*?;", "const std::wstring CREDENTIAL_FILTER = Utf8ToWide(ELEMENT_PREFERENCES_KEY_PREFIX + '*');")
    $updated = $updated.Replace("CA2W target_name((""key_"" + ELEMENT_PREFERENCES_KEY_PREFIX).c_str());", "const std::wstring target_name = Utf8ToWide(""key_"" + ELEMENT_PREFERENCES_KEY_PREFIX);")
    $updated = $updated.Replace("CredReadW(target_name.m_psz, CRED_TYPE_GENERIC, 0, &pcred);", "CredReadW(target_name.c_str(), CRED_TYPE_GENERIC, 0, &pcred);")
    $updated = $updated.Replace("CredDeleteW(target_name.m_psz, CRED_TYPE_GENERIC, 0);", "CredDeleteW(target_name.c_str(), CRED_TYPE_GENERIC, 0);")
    $updated = $updated.Replace("cred.TargetName = target_name.m_psz;", "cred.TargetName = const_cast<LPWSTR>(target_name.c_str());")
    $updated = $updated.Replace("CA2W target_name(key.c_str());", "const std::wstring target_name = Utf8ToWide(key);")
    $updated = $updated.Replace("std::string target_name = CW2A(pcred->TargetName);", "std::string target_name = pcred->TargetName ? WideToUtf8(std::wstring(pcred->TargetName)) : std::string();")

    if ($updated -eq $content) {
        throw "Secure storage patch did not change plugin file: $cppPath"
    }

    Set-Content -LiteralPath $cppPath -Value $updated -NoNewline
    Write-Host "Patched secure storage plugin: $cppPath"
}

function Resolve-LatestArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][datetime]$NotOlderThan,
        [string]$NamePattern = ""
    )

    $items = Get-ChildItem -Path $RootDir -Recurse -File -Filter "*.$Extension" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $NotOlderThan }

    if ($NamePattern) {
        $items = $items | Where-Object { $_.Name -match $NamePattern }
    }

    if (-not $items) {
        $items = Get-ChildItem -Path $RootDir -Recurse -File -Filter "*.$Extension" -ErrorAction SilentlyContinue
        if ($NamePattern) {
            $items = $items | Where-Object { $_.Name -match $NamePattern }
        }
    }

    return $items | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$workingRoot = $repoRoot
$junctionPath = $null
$isolatedWorkspace = $null
$startedAt = Get-Date

Push-Location $repoRoot
try {
    Assert-Command "flutter"
    Assert-Command "dart"

    if (-not $NoIsolatedWorkspace) {
        $isolatedWorkspace = New-IsolatedWorkspace -RepoRoot $repoRoot
        $workingRoot = $isolatedWorkspace
        Write-Host "Using isolated workspace: $isolatedWorkspace"
    }
    elseif (Test-PathHasFlutterBlockedCharacters -PathToCheck $repoRoot) {
        $junctionPath = New-CleanPathJunction -RepoRoot $repoRoot
        $workingRoot = $junctionPath
        Write-Host "Repo path has characters blocked by Flutter. Using junction: $junctionPath"
    }

    $targets = if ($Target -eq "all") { @("exe", "msix") } else { @($Target) }
    if (($targets -contains "msix") -and ($workingRoot -ne $repoRoot)) {
        # Keep repository config aligned even when packaging in isolated workspace.
        Sync-MsixVersionWithPubspec -WorkingRoot $repoRoot
    }

    Push-Location $workingRoot
    try {
        if (-not $SkipClean) {
            Write-Host "Running: flutter clean"
            & flutter clean
            if ($LASTEXITCODE -ne 0) {
                throw "flutter clean failed."
            }
        }

        Write-Host "Running: flutter pub get"
        & flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "flutter pub get failed."
        }

        if (-not $SkipSecureStoragePatch) {
            Patch-FlutterSecureStorageWindowsPlugin -WorkingRoot $workingRoot
        }

        $isccPath = $null
        if ($targets -contains "exe") {
            $isccPath = Ensure-InnoSetup -SkipInstall:$SkipDependencyInstall
        }

        if ($targets -contains "msix") {
            Sync-MsixVersionWithPubspec -WorkingRoot $workingRoot
            Ensure-Fastforge
            Ensure-MsixCertificate -WorkingRoot $workingRoot -Password $CertificatePassword -UseExistingOnly:$UseExistingCertificateOnly
        }

        foreach ($t in $targets) {
            $targetStartedAt = Get-Date

            if ($t -eq "exe") {
                Build-WindowsRelease -BuildTarget $BuildTarget -SentryDsn $SentryDsn
                Build-ExeInstaller -WorkingRoot $workingRoot -IsccPath $isccPath

                $checkExe = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "exe" -NotOlderThan $targetStartedAt -NamePattern "ZEON-Windows-Setup-x64|setup|installer|windows"
                if (-not $checkExe) {
                    throw "Installer .exe was not produced for target '$t'."
                }
                continue
            }

            $args = @(
                "package",
                "--platform", "windows",
                "--targets", $t,
                "--skip-clean",
                "--build-target", $BuildTarget
            )
            if ($SentryDsn) {
                $args += @("--build-dart-define", "sentry_dsn=$SentryDsn")
            }

            Write-Host ("Running: fastforge " + ($args -join " "))
            & fastforge @args
            if ($LASTEXITCODE -ne 0) {
                throw "fastforge package failed for target '$t'."
            }

            if ($t -eq "msix") {
                $checkMsix = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "msix" -NotOlderThan $targetStartedAt
                if (-not $checkMsix) {
                    throw "fastforge finished without producing .msix for target '$t'."
                }
            }
        }

        $workingOutDir = Join-Path $workingRoot "out\installers\win"
        $repoOutDir = Join-Path $repoRoot "out\installers\win"
        New-Item -ItemType Directory -Force -Path $workingOutDir | Out-Null
        New-Item -ItemType Directory -Force -Path $repoOutDir | Out-Null

        if ($targets -contains "exe") {
            $exe = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "exe" -NotOlderThan $startedAt -NamePattern "setup|installer|windows"
            if (-not $exe) {
                throw "Could not find built Windows setup .exe in dist."
            }
            $dstExe = Join-Path $workingOutDir "ZEON-Windows-Setup-x64.exe"
            Copy-Item -LiteralPath $exe.FullName -Destination $dstExe -Force
            Copy-Item -LiteralPath $dstExe -Destination (Join-Path $repoOutDir "ZEON-Windows-Setup-x64.exe") -Force
        }

        if ($targets -contains "msix") {
            $msix = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "msix" -NotOlderThan $startedAt
            if (-not $msix) {
                throw "Could not find built .msix in dist."
            }
            $dstMsix = Join-Path $workingOutDir "ZEON-Windows-Setup-x64.msix"
            Copy-Item -LiteralPath $msix.FullName -Destination $dstMsix -Force
            Copy-Item -LiteralPath $dstMsix -Destination (Join-Path $repoOutDir "ZEON-Windows-Setup-x64.msix") -Force
        }
    }
    finally {
        Pop-Location
    }

    $finalOut = Join-Path $repoRoot "out\installers\win"
    Write-Host ""
    Write-Host "Windows installer packaging completed successfully."
    if (Test-Path -LiteralPath (Join-Path $finalOut "ZEON-Windows-Setup-x64.exe")) {
        Write-Host ("EXE:  " + (Join-Path $finalOut "ZEON-Windows-Setup-x64.exe"))
    }
    if (Test-Path -LiteralPath (Join-Path $finalOut "ZEON-Windows-Setup-x64.msix")) {
        Write-Host ("MSIX: " + (Join-Path $finalOut "ZEON-Windows-Setup-x64.msix"))
    }
    if ($isolatedWorkspace) {
        Write-Host ("Workspace: " + $isolatedWorkspace)
    }
}
finally {
    Pop-Location
}
