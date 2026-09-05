[CmdletBinding()]
param(
    [ValidateSet("exe", "msix", "all")]
    [string]$Target = "all",

    [string]$BuildTarget = "lib/main_prod.dart",

    [string]$SentryDsn = "",

    [string]$CertificatePassword = $env:ZEON_MSIX_CERTIFICATE_PASSWORD,

    [switch]$UseExistingCertificateOnly,

    [switch]$AllowDevelopmentMsixCertificate,

    [string]$CodeSigningCertificatePath = $env:ZEON_WINDOWS_SIGNING_PFX,

    [string]$CodeSigningCertificatePassword = $env:ZEON_WINDOWS_SIGNING_PASSWORD,

    [string]$CodeSigningCertificateThumbprint = $env:ZEON_WINDOWS_SIGNING_THUMBPRINT,

    [string]$CodeSigningTimestampUrl = "http://timestamp.digicert.com",

    [switch]$AllowUnsignedExe,

    [switch]$NoIsolatedWorkspace,

    [switch]$SkipSecureStoragePatch,

    [switch]$SkipDependencyInstall,

    [switch]$SkipCodeGeneration,

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

function Resolve-SignToolPath {
    $command = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitsRoot = ${env:ProgramFiles(x86)}
    if ($kitsRoot) {
        $sdkBin = Join-Path $kitsRoot "Windows Kits\10\bin"
        if (Test-Path -LiteralPath $sdkBin) {
            $candidate = Get-ChildItem -LiteralPath $sdkBin -Directory |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($candidate) {
                return $candidate
            }
        }
    }

    throw "signtool.exe was not found. Install the Windows SDK signing tools."
}

function Invoke-AuthenticodeSigning {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SignToolPath,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$TimestampUrl
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Signing target was not found: $Path"
    }

    $args = @("sign", "/fd", "SHA256")
    if ($CertificateThumbprint) {
        $args += @("/sha1", $CertificateThumbprint)
    }
    else {
        if (-not $CertificatePath -or -not (Test-Path -LiteralPath $CertificatePath)) {
            throw "Code-signing PFX was not found: $CertificatePath"
        }
        $args += @("/f", $CertificatePath)
        if ($CertificatePassword) {
            $args += @("/p", $CertificatePassword)
        }
    }
    if ($TimestampUrl) {
        $args += @("/tr", $TimestampUrl, "/td", "SHA256")
    }
    $args += $Path

    Write-Host "Authenticode signing: $Path"
    & $SignToolPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode signing failed: $Path"
    }
    & $SignToolPath verify /pa /q $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode verification failed: $Path"
    }
}

function Protect-WindowsReleasePayload {
    param(
        [Parameter(Mandatory = $true)][string]$ReleaseDir,
        [Parameter(Mandatory = $true)][string]$SignToolPath,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$TimestampUrl
    )

    $binaries = Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File |
        Where-Object { $_.Extension -in @(".exe", ".dll") }
    foreach ($binary in $binaries) {
        $signature = Get-AuthenticodeSignature -LiteralPath $binary.FullName
        if ($signature.Status -eq "Valid") {
            continue
        }
        if ($signature.Status -ne "NotSigned") {
            throw "Refusing to package binary with invalid signature ($($signature.Status)): $($binary.FullName)"
        }
        Invoke-AuthenticodeSigning `
            -Path $binary.FullName `
            -SignToolPath $SignToolPath `
            -CertificatePath $CertificatePath `
            -CertificatePassword $CertificatePassword `
            -CertificateThumbprint $CertificateThumbprint `
            -TimestampUrl $TimestampUrl
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

function Resolve-FlutterPackageRoot {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingRoot,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $pluginLink = Join-Path $WorkingRoot "windows\flutter\ephemeral\.plugin_symlinks\$PackageName"
    if (Test-Path -LiteralPath $pluginLink) {
        $pluginItem = Get-Item -LiteralPath $pluginLink
        if (-not $pluginItem.Target) {
            throw "Plugin symlink target is empty: $pluginLink"
        }

        $pluginTarget = $pluginItem.Target
        if ($pluginTarget -is [Array]) {
            $pluginTarget = $pluginTarget[0]
        }
        return $pluginTarget
    }

    $packageConfigPath = Join-Path $WorkingRoot ".dart_tool\package_config.json"
    if (-not (Test-Path -LiteralPath $packageConfigPath)) {
        throw "Package config not found: $packageConfigPath. Run 'flutter pub get' first."
    }

    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
    $package = $packageConfig.packages | Where-Object { $_.name -eq $PackageName } | Select-Object -First 1
    if (-not $package) {
        throw "Package $PackageName was not found in $packageConfigPath."
    }

    $rootUri = [string]$package.rootUri
    if ($rootUri.StartsWith("file:")) {
        return ([Uri]$rootUri).LocalPath
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $packageConfigPath) $rootUri))
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
    $build = $major * 10000 + $minor * 100 + $patch
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

function Invoke-DartCodeGeneration {
    Write-Host "Running: dart run build_runner build --delete-conflicting-outputs"
    & dart run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) {
        throw "Dart code generation failed."
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
    $appUserModelId = Get-YamlScalar -Path $configPath -Key "app_user_model_id"
    $toastActivatorClsid = Get-YamlScalar -Path $configPath -Key "toast_activator_clsid"
    $publisher = Get-YamlScalar -Path $configPath -Key "publisher"
    $publisherUrl = Get-YamlScalar -Path $configPath -Key "publisher_url"
    $displayName = Get-YamlScalar -Path $configPath -Key "display_name"
    $installDirName = Get-YamlScalar -Path $configPath -Key "install_dir_name"
    $setupIconFile = Get-YamlScalar -Path $configPath -Key "setup_icon_file"
    $createDesktopIconRaw = Get-YamlScalar -Path $configPath -Key "create_desktop_icon"
    $launchAtStartupRaw = Get-YamlScalar -Path $configPath -Key "launch_at_startup"

    if (-not $appId) { $appId = [guid]::NewGuid().ToString() }
    if (-not $appUserModelId) { $appUserModelId = "ZEON.ZEON" }
    if (-not $toastActivatorClsid) { $toastActivatorClsid = "6f903538-42b1-4596-a479-bb779f21a65d" }
    if (-not $publisher) { $publisher = "ZEON" }
    if (-not $publisherUrl) { $publisherUrl = "https://github.com/actemendes/zeon-app" }
    if (-not $displayName) { $displayName = "ZEON" }
    if (-not $installDirName) { $installDirName = "{localappdata}\Programs\ZEON" }
    if (-not $setupIconFile) { $setupIconFile = "windows\runner\resources\app_icon.ico" }
    $createDesktopIcon = $createDesktopIconRaw -notmatch '^(?i:false|0|no)$'
    $launchAtStartup = $launchAtStartupRaw -notmatch '^(?i:false|0|no)$'

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
    Write-Host "EXE installer version from pubspec.yaml: $versionRaw -> $version"

    $distDir = Join-Path $WorkingRoot "dist\zeon"
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    $issPath = Join-Path $WorkingRoot "build\windows\zeon_installer.iss"

    $releaseDirForIss = $releaseDir -replace '/', '\'
    $iconForIss = (Join-Path $WorkingRoot $setupIconFile) -replace '/', '\'
    $distDirForIss = $distDir -replace '/', '\'
    $desktopIconFlags = if ($createDesktopIcon) { "checkedonce" } else { "unchecked" }
    $startupFlags = if ($launchAtStartup) { "checkedonce" } else { "unchecked" }

    $iss = @"
[Setup]
AppId=${appId}
AppName=${displayName}
AppVersion=${version}
AppVerName=${displayName} ${version}
AppPublisher=${publisher}
AppPublisherURL=${publisherUrl}
AppSupportURL=${publisherUrl}
AppUpdatesURL=${publisherUrl}
DefaultDirName=${installDirName}
DefaultGroupName=${displayName}
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
CloseApplicationsFilter=${exeName},ZEON.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: ${desktopIconFlags}
Name: "launchAtStartup"; Description: "Start ${displayName} when Windows starts"; GroupDescription: "{cm:AdditionalIcons}"; Flags: ${startupFlags}

[InstallDelete]
Type: files; Name: "{userstartup}\ZEON.lnk"

[Files]
Source: "${releaseDirForIss}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\${displayName}"; Filename: "{app}\${exeName}"; AppUserModelID: "${appUserModelId}"; AppUserModelToastActivatorCLSID: "${toastActivatorClsid}"
Name: "{autodesktop}\${displayName}"; Filename: "{app}\${exeName}"; Tasks: desktopicon; AppUserModelID: "${appUserModelId}"; AppUserModelToastActivatorCLSID: "${toastActivatorClsid}"
Name: "{userstartup}\${displayName}"; Filename: "{app}\${exeName}"; WorkingDir: "{app}"; Tasks: launchAtStartup; AppUserModelID: "${appUserModelId}"; AppUserModelToastActivatorCLSID: "${toastActivatorClsid}"

[Run]
Filename: "{app}\${exeName}"; Description: "{cm:LaunchProgram,${displayName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\${exeName}"; Parameters: "--recover-system-proxy"; Flags: runhidden waituntilterminated skipifdoesntexist; RunOnceId: "ZEONSystemProxyRecovery"
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
        "linux\flutter\ephemeral",
        "macos\Flutter\ephemeral",
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
        [string]$Password,
        [switch]$UseExistingOnly,
        [switch]$AllowDevelopmentCertificate
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
        if ($UseExistingOnly -or -not $AllowDevelopmentCertificate) {
            throw "MSIX certificate was not found: $certPath. Provide the production certificate, or use -AllowDevelopmentMsixCertificate only for local testing."
        }

        if (-not $Password) {
            throw "A non-empty MSIX certificate password is required for development certificate generation."
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

    if (-not $Password) {
        throw "The MSIX certificate password is required. Prefer ZEON_MSIX_CERTIFICATE_PASSWORD over a command-line argument."
    }

    Set-YamlScalar -Path $configPath -Key "certificate_password" -Value $Password -QuoteValue
    return $configPath
}

function Patch-FlutterSecureStorageWindowsPlugin {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $pluginLink = Join-Path $WorkingRoot "windows\flutter\ephemeral\.plugin_symlinks\flutter_secure_storage_windows"
    $pluginTarget = $null
    if (Test-Path -LiteralPath $pluginLink) {
        $pluginItem = Get-Item -LiteralPath $pluginLink
        if (-not $pluginItem.Target) {
            throw "Plugin symlink target is empty: $pluginLink"
        }

        $pluginTarget = $pluginItem.Target
        if ($pluginTarget -is [Array]) {
            $pluginTarget = $pluginTarget[0]
        }
    }
    else {
        $packageConfigPath = Join-Path $WorkingRoot ".dart_tool\package_config.json"
        if (-not (Test-Path -LiteralPath $packageConfigPath)) {
            throw "Package config not found: $packageConfigPath. Run 'flutter pub get' first."
        }

        $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
        $package = $packageConfig.packages | Where-Object { $_.name -eq "flutter_secure_storage_windows" } | Select-Object -First 1
        if (-not $package) {
            throw "Package flutter_secure_storage_windows was not found in $packageConfigPath."
        }

        $rootUri = [string]$package.rootUri
        if ($rootUri.StartsWith("file:")) {
            $pluginTarget = ([Uri]$rootUri).LocalPath
        }
        else {
            $pluginTarget = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $packageConfigPath) $rootUri))
        }
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

function Patch-FlutterLocalNotificationsWindowsPlugin {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $pluginLink = Join-Path $WorkingRoot "windows\flutter\ephemeral\.plugin_symlinks\flutter_local_notifications_windows"
    $pluginTarget = $null
    if (Test-Path -LiteralPath $pluginLink) {
        $pluginItem = Get-Item -LiteralPath $pluginLink
        if (-not $pluginItem.Target) {
            throw "Plugin symlink target is empty: $pluginLink"
        }

        $pluginTarget = $pluginItem.Target
        if ($pluginTarget -is [Array]) {
            $pluginTarget = $pluginTarget[0]
        }
    }
    else {
        $packageConfigPath = Join-Path $WorkingRoot ".dart_tool\package_config.json"
        if (-not (Test-Path -LiteralPath $packageConfigPath)) {
            throw "Package config not found: $packageConfigPath. Run 'flutter pub get' first."
        }

        $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
        $package = $packageConfig.packages | Where-Object { $_.name -eq "flutter_local_notifications_windows" } | Select-Object -First 1
        if (-not $package) {
            throw "Package flutter_local_notifications_windows was not found in $packageConfigPath."
        }

        $rootUri = [string]$package.rootUri
        if ($rootUri.StartsWith("file:")) {
            $pluginTarget = ([Uri]$rootUri).LocalPath
        }
        else {
            $pluginTarget = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $packageConfigPath) $rootUri))
        }
    }

    $cppPath = Join-Path $pluginTarget "src\plugin.cpp"
    if (-not (Test-Path -LiteralPath $cppPath)) {
        throw "Plugin source file not found: $cppPath"
    }

    $content = Get-Content -LiteralPath $cppPath -Raw
    $hasLegacyAtlTokens = $content -match "atlbase\.h|CW2A"
    $hasHelperFunction = $content -match "std::string\s+WideToUtf8\s*\("

    if (-not $hasLegacyAtlTokens -and $hasHelperFunction) {
        Write-Host "flutter_local_notifications_windows is already ATL-free."
        return
    }

    $updated = $content
    $updated = $updated.Replace("#include <atlbase.h>`r`n", "")
    $updated = $updated.Replace("#include <atlbase.h>`n", "")

    if (-not $hasHelperFunction) {
        $anchorPattern = '(#include "utils\.hpp"\r?\n)'
        if ($updated -notmatch $anchorPattern) {
            throw "Could not find insertion anchor for helper functions in: $cppPath"
        }

        $helperBlock = @"

namespace {
std::string WideToUtf8(LPCWSTR value) {
  if (value == nullptr || value[0] == L'\0') {
    return std::string();
  }
  const int required = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  winrt::check_win32(required > 0 ? ERROR_SUCCESS : GetLastError());
  std::string utf8(static_cast<size_t>(required), '\0');
  const int converted = WideCharToMultiByte(CP_UTF8, 0, value, -1, utf8.data(), required, nullptr, nullptr);
  winrt::check_win32(converted > 0 ? ERROR_SUCCESS : GetLastError());
  if (!utf8.empty() && utf8.back() == '\0') {
    utf8.pop_back();
  }
  return utf8;
}
}
"@
        $updated = [regex]::Replace($updated, $anchorPattern, "`$1$helperBlock")
    }

    $updated = $updated.Replace("const std::string key = CW2A(item.Key, CP_UTF8);", "const std::string key = WideToUtf8(item.Key);")
    $updated = $updated.Replace("const std::string value = CW2A(item.Value, CP_UTF8);", "const std::string value = WideToUtf8(item.Value);")
    $updated = $updated.Replace("const auto payload = string(CW2A(args, CP_UTF8));", "const auto payload = WideToUtf8(args);")

    if ($updated -eq $content) {
        throw "Local notifications patch did not change plugin file: $cppPath"
    }

    Set-Content -LiteralPath $cppPath -Value $updated -NoNewline
    Write-Host "Patched local notifications plugin: $cppPath"
}

function Patch-TrayManagerWindowsPlugin {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $pluginTarget = Resolve-FlutterPackageRoot -WorkingRoot $WorkingRoot -PackageName "tray_manager"
    $cppPath = Join-Path $pluginTarget "windows\tray_manager_plugin.cpp"
    if (-not (Test-Path -LiteralPath $cppPath)) {
        throw "tray_manager Windows source file not found: $cppPath"
    }

    $content = Get-Content -LiteralPath $cppPath -Raw
    if ($content -match "DestroyMenuTree" -and $content -match "HICON previousIcon") {
        Write-Host "tray_manager Windows resource patch is already applied."
        return
    }

    $updated = $content
    $updated = $updated.Replace("  NOTIFYICONDATA nid;", "  NOTIFYICONDATA nid{};")
    $updated = $updated.Replace("  NOTIFYICONIDENTIFIER niif;", "  NOTIFYICONIDENTIFIER niif{};")

    if ($updated -notmatch "DestroyMenuTree") {
        $updated = [regex]::Replace(
            $updated,
            "(?s)(const flutter::EncodableValue\* ValueOrNull.*?\n}\r?\n)",
            "`$1`r`nvoid DestroyMenuTree(HMENU menu) {`r`n  int count = GetMenuItemCount(menu);`r`n  for (int i = count - 1; i >= 0; i--) {`r`n    MENUITEMINFO item_info{};`r`n    item_info.cbSize = sizeof(MENUITEMINFO);`r`n    item_info.fMask = MIIM_SUBMENU;`r`n    if (GetMenuItemInfo(menu, i, TRUE, &item_info) && item_info.hSubMenu != nullptr) {`r`n      DestroyMenuTree(item_info.hSubMenu);`r`n      DestroyMenu(item_info.hSubMenu);`r`n    }`r`n  }`r`n}`r`n"
        )
    }

    $updated = [regex]::Replace(
        $updated,
        "  int count = GetMenuItemCount\(menu\);\r?\n  for \(int i = 0; i < count; i\+\+\) \{\r?\n    // always remove at 0 because they shift every time\r?\n    RemoveMenu\(menu, 0, MF_BYPOSITION\);\r?\n  \}",
        "  DestroyMenuTree(menu);`r`n  int count = GetMenuItemCount(menu);`r`n  for (int i = count - 1; i >= 0; i--) {`r`n    RemoveMenu(menu, i, MF_BYPOSITION);`r`n  }"
    )

    $updated = [regex]::Replace(
        $updated,
        "TrayManagerPlugin::~TrayManagerPlugin\(\) \{\r?\n  registrar->UnregisterTopLevelWindowProcDelegate\(window_proc_id\);\r?\n\}",
        "TrayManagerPlugin::~TrayManagerPlugin() {`r`n  registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);`r`n  DestroyMenuTree(hMenu);`r`n  DestroyMenu(hMenu);`r`n}"
    )

    $updated = [regex]::Replace(
        $updated,
        "if \(tray_icon_setted\) \{\r?\n      Shell_NotifyIcon\(NIM_DELETE, &nid\);\r?\n      DestroyIcon\(nid\.hIcon\);\r?\n    \}",
        "if (tray_icon_setted) {`r`n      Shell_NotifyIcon(NIM_DELETE, &nid);`r`n    }`r`n    if (nid.hIcon != nullptr) {`r`n      DestroyIcon(nid.hIcon);`r`n      nid.hIcon = nullptr;`r`n    }"
    )

    $updated = [regex]::Replace(
        $updated,
        "void TrayManagerPlugin::Destroy\(\r?\n    const flutter::MethodCall<flutter::EncodableValue>& method_call,\r?\n    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result\) \{\r?\n  Shell_NotifyIcon\(NIM_DELETE, &nid\);\r?\n  DestroyIcon\(nid\.hIcon\);\r?\n  tray_icon_setted = false;",
        "void TrayManagerPlugin::Destroy(`r`n    const flutter::MethodCall<flutter::EncodableValue>& method_call,`r`n    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {`r`n  if (tray_icon_setted) {`r`n    Shell_NotifyIcon(NIM_DELETE, &nid);`r`n  }`r`n  if (nid.hIcon != nullptr) {`r`n    DestroyIcon(nid.hIcon);`r`n    nid.hIcon = nullptr;`r`n  }`r`n  tray_icon_setted = false;"
    )

    $updated = [regex]::Replace(
        $updated,
        "  nid\.hIcon = static_cast<HICON>\(\r?\n      LoadImage\(nullptr, \(LPCWSTR\)\(converter\.from_bytes\(iconPath\)\.c_str\(\)\),\r?\n                IMAGE_ICON, GetSystemMetrics\(SM_CXSMICON\),\r?\n                GetSystemMetrics\(SM_CYSMICON\), LR_LOADFROMFILE\)\);\r?\n\r?\n  _ApplyIcon\(\);",
        "  HICON previousIcon = nid.hIcon;`r`n  nid.hIcon = static_cast<HICON>(`r`n      LoadImage(nullptr, (LPCWSTR)(converter.from_bytes(iconPath).c_str()),`r`n                IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),`r`n                GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));`r`n`r`n  _ApplyIcon();`r`n`r`n  if (previousIcon != nullptr && previousIcon != nid.hIcon) {`r`n    DestroyIcon(previousIcon);`r`n  }"
    )

    if ($updated -eq $content -or $updated -notmatch "DestroyMenuTree" -or $updated -notmatch "HICON previousIcon") {
        throw "tray_manager Windows resource patch did not apply cleanly: $cppPath"
    }

    Set-Content -LiteralPath $cppPath -Value $updated -NoNewline
    Write-Host "Patched tray_manager Windows resource cleanup: $cppPath"
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
$signToolPath = $null
$msixConfigWithPassword = $null
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
    if ($targets -contains "exe") {
        if ($CodeSigningCertificatePath -and $CodeSigningCertificateThumbprint) {
            throw "Specify either a code-signing PFX path or a certificate thumbprint, not both."
        }
        if (-not $AllowUnsignedExe -and -not $CodeSigningCertificatePath -and -not $CodeSigningCertificateThumbprint) {
            throw "Release EXE packaging requires Authenticode signing. Set ZEON_WINDOWS_SIGNING_PFX (and ZEON_WINDOWS_SIGNING_PASSWORD) or ZEON_WINDOWS_SIGNING_THUMBPRINT. Use -AllowUnsignedExe only for local testing."
        }
        if (-not $AllowUnsignedExe) {
            if ($CodeSigningCertificatePath -and -not [System.IO.Path]::IsPathRooted($CodeSigningCertificatePath)) {
                $CodeSigningCertificatePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $CodeSigningCertificatePath))
            }
            $signToolPath = Resolve-SignToolPath
        }
    }
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

        if (-not $SkipCodeGeneration) {
            Invoke-DartCodeGeneration
        }

        if (-not $SkipSecureStoragePatch) {
            Patch-FlutterSecureStorageWindowsPlugin -WorkingRoot $workingRoot
        }
        Patch-FlutterLocalNotificationsWindowsPlugin -WorkingRoot $workingRoot
        Patch-TrayManagerWindowsPlugin -WorkingRoot $workingRoot

        $isccPath = $null
        if ($targets -contains "exe") {
            $isccPath = Ensure-InnoSetup -SkipInstall:$SkipDependencyInstall
        }

        if ($targets -contains "msix") {
            Sync-MsixVersionWithPubspec -WorkingRoot $workingRoot
            Ensure-Fastforge
            $msixConfigWithPassword = Ensure-MsixCertificate `
                -WorkingRoot $workingRoot `
                -Password $CertificatePassword `
                -UseExistingOnly:$UseExistingCertificateOnly `
                -AllowDevelopmentCertificate:$AllowDevelopmentMsixCertificate
        }

        foreach ($t in $targets) {
            $targetStartedAt = Get-Date

            if ($t -eq "exe") {
                Build-WindowsRelease -BuildTarget $BuildTarget -SentryDsn $SentryDsn
                $releaseDir = Join-Path $workingRoot "build\windows\x64\runner\Release"
                if ($AllowUnsignedExe) {
                    Write-Warning "Building an unsigned EXE payload. Do not distribute this local-test artifact."
                }
                else {
                    Protect-WindowsReleasePayload `
                        -ReleaseDir $releaseDir `
                        -SignToolPath $signToolPath `
                        -CertificatePath $CodeSigningCertificatePath `
                        -CertificatePassword $CodeSigningCertificatePassword `
                        -CertificateThumbprint $CodeSigningCertificateThumbprint `
                        -TimestampUrl $CodeSigningTimestampUrl
                }
                Build-ExeInstaller -WorkingRoot $workingRoot -IsccPath $isccPath

                $checkExe = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "exe" -NotOlderThan $targetStartedAt -NamePattern "ZEON-Windows-Setup-x64|setup|installer|windows"
                if (-not $checkExe) {
                    throw "Installer .exe was not produced for target '$t'."
                }
                if (-not $AllowUnsignedExe) {
                    Invoke-AuthenticodeSigning `
                        -Path $checkExe.FullName `
                        -SignToolPath $signToolPath `
                        -CertificatePath $CodeSigningCertificatePath `
                        -CertificatePassword $CodeSigningCertificatePassword `
                        -CertificateThumbprint $CodeSigningCertificateThumbprint `
                        -TimestampUrl $CodeSigningTimestampUrl
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
            $repoDstExe = Join-Path $repoOutDir "ZEON-Windows-Setup-x64.exe"
            Copy-Item -LiteralPath $exe.FullName -Destination $dstExe -Force
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFullPath($dstExe), [System.IO.Path]::GetFullPath($repoDstExe))) {
                Copy-Item -LiteralPath $dstExe -Destination $repoDstExe -Force
            }
        }

        if ($targets -contains "msix") {
            $msix = Resolve-LatestArtifact -RootDir (Join-Path $workingRoot "dist") -Extension "msix" -NotOlderThan $startedAt
            if (-not $msix) {
                throw "Could not find built .msix in dist."
            }
            $dstMsix = Join-Path $workingOutDir "ZEON-Windows-Setup-x64.msix"
            $repoDstMsix = Join-Path $repoOutDir "ZEON-Windows-Setup-x64.msix"
            Copy-Item -LiteralPath $msix.FullName -Destination $dstMsix -Force
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFullPath($dstMsix), [System.IO.Path]::GetFullPath($repoDstMsix))) {
                Copy-Item -LiteralPath $dstMsix -Destination $repoDstMsix -Force
            }
        }
    }
    finally {
        if ($msixConfigWithPassword -and (Test-Path -LiteralPath $msixConfigWithPassword)) {
            Set-YamlScalar -Path $msixConfigWithPassword -Key "certificate_password" -Value "" -QuoteValue
        }
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
