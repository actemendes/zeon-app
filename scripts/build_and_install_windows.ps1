[CmdletBinding()]
param(
    [ValidateSet("release", "debug", "profile")]
    [string]$BuildMode = "release",

    [switch]$Launch,

    [switch]$SkipSecureStoragePatch,

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

function Invoke-FlutterPubGet {
    Write-Host "Running: flutter pub get"
    & flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw "flutter pub get failed."
    }
}

function Test-MissingWindowsFlutterWrapperSources {
    param([Parameter(Mandatory = $true)][string]$WorkingRoot)

    $wrapperDir = Join-Path $WorkingRoot "windows\flutter\ephemeral\cpp_client_wrapper"
    $requiredSources = @(
        "core_implementations.cc"
        "standard_codec.cc"
        "plugin_registrar.cc"
        "flutter_engine.cc"
        "flutter_view_controller.cc"
    )

    foreach ($sourceFile in $requiredSources) {
        $sourcePath = Join-Path $wrapperDir $sourceFile
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            return $true
        }
    }

    return $false
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

function Get-BuildConfigName {
    param([Parameter(Mandatory = $true)][string]$Mode)

    switch ($Mode) {
        "release" { return "Release" }
        "debug" { return "Debug" }
        "profile" { return "Profile" }
        default { throw "Unsupported build mode '$Mode'." }
    }
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

function Resolve-BuiltExePath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingRoot,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    $buildConfig = Get-BuildConfigName -Mode $Mode
    $runnerDir = Join-Path $WorkingRoot "build\windows\x64\runner\$buildConfig"
    if (-not (Test-Path -LiteralPath $runnerDir)) {
        throw "Windows build output directory was not found: $runnerDir"
    }

    $exeCandidates = Get-ChildItem -LiteralPath $runnerDir -Filter "*.exe" |
        Where-Object { $_.Name -notmatch '^unins\d+\.exe$' -and $_.Name -notmatch 'Cli\.exe$' }

    $exe = $exeCandidates | Where-Object { $_.Name -ieq "ZEON.exe" } | Select-Object -First 1
    if (-not $exe) {
        $exe = $exeCandidates | Sort-Object Name | Select-Object -First 1
    }

    if (-not $exe) {
        throw "No application .exe found in $runnerDir"
    }

    return $exe.FullName
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$workingRoot = $repoRoot
$junctionPath = $null
$shouldRunClean = -not $SkipClean

Push-Location $repoRoot
try {
    Assert-Command "flutter"

    if (Test-PathHasFlutterBlockedCharacters -PathToCheck $repoRoot) {
        $junctionPath = New-CleanPathJunction -RepoRoot $repoRoot
        $workingRoot = $junctionPath
        Write-Host "Repo path has characters blocked by Flutter. Using junction: $junctionPath"

        if ($SkipClean) {
            Write-Warning "SkipClean is not reliable when building via junction path. Running flutter clean to avoid missing wrapper sources."
            $shouldRunClean = $true
        }
    }

    Push-Location $workingRoot
    try {
        if ($shouldRunClean) {
            Write-Host "Running: flutter clean"
            & flutter clean
            if ($LASTEXITCODE -ne 0) {
                throw "flutter clean failed."
            }
        }

        Invoke-FlutterPubGet

        if (-not $SkipSecureStoragePatch) {
            Patch-FlutterSecureStorageWindowsPlugin -WorkingRoot $workingRoot
        }

        $buildArgs = @("build", "windows", "--$BuildMode")
        Write-Host ("Running: flutter " + ($buildArgs -join " "))
        & flutter @buildArgs
        if ($LASTEXITCODE -ne 0) {
            $wrapperMissingAfterBuildFailure = Test-MissingWindowsFlutterWrapperSources -WorkingRoot $workingRoot
            if ($wrapperMissingAfterBuildFailure) {
                Write-Warning "Windows Flutter wrapper sources became unavailable during build. Retrying after flutter clean."
                Write-Host "Running: flutter clean"
                & flutter clean
                if ($LASTEXITCODE -ne 0) {
                    throw "flutter clean failed during build retry."
                }

                Invoke-FlutterPubGet

                if (-not $SkipSecureStoragePatch) {
                    Patch-FlutterSecureStorageWindowsPlugin -WorkingRoot $workingRoot
                }

                Write-Host ("Retrying: flutter " + ($buildArgs -join " "))
                & flutter @buildArgs
            }

            if ($LASTEXITCODE -ne 0) {
                throw "flutter build windows failed."
            }
        }
    }
    finally {
        Pop-Location
    }

    $exePath = Resolve-BuiltExePath -WorkingRoot $workingRoot -Mode $BuildMode
    $exePathInRepo = $exePath
    if ($junctionPath) {
        $buildConfig = Get-BuildConfigName -Mode $BuildMode
        $repoCandidate = Join-Path $repoRoot ("build\windows\x64\runner\" + $buildConfig + "\" + [System.IO.Path]::GetFileName($exePath))
        if (Test-Path -LiteralPath $repoCandidate) {
            $exePathInRepo = $repoCandidate
        }
    }

    Write-Host ""
    Write-Host "Windows build completed successfully."
    Write-Host "EXE (working path): $exePath"
    if ($exePathInRepo -ne $exePath) {
        Write-Host "EXE (repo path):    $exePathInRepo"
    }

    if ($Launch) {
        Write-Host "Launching: $exePath"
        Start-Process -FilePath $exePath | Out-Null
    }
}
finally {
    Pop-Location
}
