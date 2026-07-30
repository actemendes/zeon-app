[CmdletBinding()]
param(
    [ValidateSet("android", "windows", "linux")]
    [string[]]$Platform = @("windows"),

    [string]$WslDistribution,

    [switch]$SkipGoModDownload,

    [switch]$SkipGomobileInit,

    [switch]$InstallPinnedMobileTools,

    [switch]$InstallWebDependencies,

    # Adds the smart_active_debug Go build tag. Never use this for releases.
    [switch]$SmartActiveDebug,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $wslArguments = @()
    if ($WslDistribution) {
        $wslArguments += @("--distribution", $WslDistribution)
    }
    $wslArguments += "--"
    $wslArguments += $Arguments

    if ($CaptureOutput) {
        $output = & wsl.exe @wslArguments
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed: wsl.exe $($wslArguments -join ' ')"
        }
        return (($output | Out-String).Trim())
    }

    & wsl.exe @wslArguments
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed: wsl.exe $($wslArguments -join ' ')"
    }
}

function Get-WslCommandPrefix {
    $wslArguments = @()
    if ($WslDistribution) {
        $wslArguments += @("--distribution", $WslDistribution)
    }
    return $wslArguments
}

function Get-WslDistributionList {
    $output = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return (($output -replace "[`0`r`n]", "") | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join ", "
}

function Assert-WslBash {
    $wslArguments = Get-WslCommandPrefix
    $wslArguments += @("--", "sh", "-lc", "command -v bash >/dev/null 2>&1")

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & wsl.exe @wslArguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -eq 0) {
        return
    }

    $selectedDistribution = if ($WslDistribution) { $WslDistribution } else { "the default WSL distribution" }
    $availableDistributions = Get-WslDistributionList
    $hint = "Install a regular Linux distribution, for example: wsl --install -d Ubuntu-24.04"
    if ($WslDistribution) {
        $hint = "Install bash in '$WslDistribution' or pass a different -WslDistribution value."
    }
    elseif ($availableDistributions -match "(^|,\s*)docker-desktop($|,)") {
        $hint = "Your default WSL distribution appears to be docker-desktop. Set Ubuntu as default with 'wsl --set-default Ubuntu-24.04', or pass -WslDistribution Ubuntu-24.04."
    }

    $details = if ($availableDistributions) { " Available WSL distributions: $availableDistributions." } else { "" }
    throw "Required command 'bash' was not found inside $selectedDistribution.$details $hint"
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$coreDir = Join-Path $repoRoot "hiddify-core"
$zeonRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
$hiddifyCoreTree = (& git -C $repoRoot rev-parse "HEAD:hiddify-core").Trim()
$hiddifySingBoxTree = (& git -C $repoRoot rev-parse "HEAD:hiddify-core/hiddify-sing-box").Trim()
if ($LASTEXITCODE -ne 0 -or -not $zeonRevision -or -not $hiddifyCoreTree -or -not $hiddifySingBoxTree) {
    throw "Failed to resolve ZEON/core source provenance from Git."
}
& git -C $repoRoot diff --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Tracked worktree changes are present. Commit them before building the baseline core."
}
& git -C $repoRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Staged worktree changes are present. Commit them before building the baseline core."
}

Assert-Command "wsl.exe"
Assert-WslBash

if (-not (Test-Path -LiteralPath (Join-Path $coreDir "go.mod"))) {
    throw "hiddify-core sources were not found: $coreDir"
}

$escapedRepoRoot = $repoRoot.Replace("\", "\\")
$wslRepoRoot = Invoke-Wsl -Arguments @("wslpath", "-a", "-u", $escapedRepoRoot) -CaptureOutput
if (-not $wslRepoRoot) {
    throw "Failed to resolve the repository path inside WSL."
}

$skipGoModDownloadValue = if ($SkipGoModDownload) { "1" } else { "0" }
$skipGomobileInitValue = if ($SkipGomobileInit) { "1" } else { "0" }
$installPinnedMobileToolsValue = if ($InstallPinnedMobileTools) { "1" } else { "0" }
$installWebDependenciesValue = if ($InstallWebDependencies) { "1" } else { "0" }
$smartActiveDebugValue = if ($SmartActiveDebug) { "1" } else { "0" }
$selectedPlatforms = @($Platform | Select-Object -Unique)

$bashScript = @'
set -euo pipefail

repo_root="$1"
skip_go_mod_download="$2"
skip_gomobile_init="$3"
install_pinned_mobile_tools="$4"
install_web_dependencies="$5"
smart_active_debug="$6"
zeon_revision="$7"
hiddify_core_tree="$8"
hiddify_sing_box_tree="$9"
shift 9
platforms=("$@")

core_dir="$repo_root/hiddify-core"
android_aar="$repo_root/android/app/libs/hiddify-core.aar"
core_build_tags="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack"
if [ "$smart_active_debug" = "1" ]; then
  core_build_tags="$core_build_tags,smart_active_debug"
  echo "Building Smart Active debug fault injection support."
fi

user_home="$(getent passwd "$(id -un)" | cut -d: -f6)"
if [ -z "$user_home" ] || [ ! -d "$user_home" ]; then
  echo "Unable to resolve the WSL user's home directory." >&2
  exit 1
fi
export HOME="$user_home"
export GOPATH="$user_home/go"
export PATH="$GOPATH/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
export GOFLAGS="-buildvcs=false"
export SOURCE_DATE_EPOCH="0"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found inside WSL." >&2
    exit 1
  fi
}

require_directory() {
  if [ ! -d "$1" ]; then
    echo "Required directory was not found: $1" >&2
    exit 1
  fi
}

require_directory "$core_dir"

required_go_version="$(awk '$1 == "go" { print $2; exit }' "$core_dir/go.mod")"
require_command go
if [ -z "$required_go_version" ]; then
  echo "$core_dir/go.mod does not declare a Go version." >&2
  exit 1
fi
export GOTOOLCHAIN="go$required_go_version"
actual_go_version="$(go env GOVERSION)"
if [ "$actual_go_version" != "go$required_go_version" ]; then
  echo "Go toolchain mismatch: expected go$required_go_version, got $actual_go_version" >&2
  exit 1
fi
echo "Using Go toolchain: $(go version)"

if [ "$skip_go_mod_download" != "1" ]; then
  echo "Downloading Go modules..."
  (cd "$core_dir" && go mod download)
fi

if [ "$install_web_dependencies" = "1" ]; then
  require_command npm
  echo "Installing hiddify-core web extension dependencies..."
  (cd "$core_dir" && npm install)
fi

for platform in "${platforms[@]}"; do
  case "$platform" in
    android)
      require_command java

      export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
      export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
      export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.2.13676358}"
      export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"

      require_directory "$ANDROID_HOME"
      require_directory "$ANDROID_NDK_HOME"
      ndk_revision="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ANDROID_NDK_HOME/source.properties" | head -n 1)"
      if [ "$ndk_revision" != "28.2.13676358" ]; then
        echo "Android NDK mismatch: expected 28.2.13676358, got ${ndk_revision:-unknown}" >&2
        exit 1
      fi

      if [ "$install_pinned_mobile_tools" = "1" ]; then
        echo "Installing explicitly requested pinned gomobile tools..."
        go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.11
        go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.11
      fi
      require_command gomobile
      require_command gobind
      for mobile_tool in gomobile gobind; do
        tool_metadata="$(go version -m "$(command -v "$mobile_tool")")"
        if ! printf '%s\n' "$tool_metadata" | grep -Eq $'\tmod\tgithub.com/sagernet/gomobile\tv0\\.1\\.11([[:space:]]|$)'; then
          echo "$mobile_tool version mismatch: expected github.com/sagernet/gomobile v0.1.11" >&2
          printf '%s\n' "$tool_metadata" >&2
          exit 1
        fi
        if ! printf '%s\n' "$tool_metadata" | head -n 1 | grep -q 'go1.25.6'; then
          echo "$mobile_tool was not built with baseline Go 1.25.6" >&2
          exit 1
        fi
      done

      if [ "$skip_gomobile_init" != "1" ]; then
        echo "Initializing gomobile..."
        gomobile init -v
      fi

      echo "Building Android AAR..."
      mkdir -p "$core_dir/bin" "$(dirname "$android_aar")"
      (
        cd "$core_dir"
        build_metadata_ldflags="-X github.com/hiddify/hiddify-core/platform/mobile.buildRevision=$zeon_revision"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.hiddifyCoreTree=$hiddify_core_tree"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.hiddifySingBoxTree=$hiddify_sing_box_tree"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.coreBuildTags=$core_build_tags"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.upstreamVersion=v1.13.14"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.upstreamCommit=25a600db24f7680ad9806ce5427bd0ab8afe1114"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.hiddifyCompatibilityRevision=$hiddify_core_tree"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.zeonPatchRevision=$hiddify_sing_box_tree"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.sourceDirty=false"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.gomobileVersion=v0.1.11"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.androidNDKVersion=28.2.13676358"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.buildTimestampPolicy=SOURCE_DATE_EPOCH=0"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/mobile.buildIDPolicy=empty"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/hiddify/hiddify-core/v2/hcommon/constants.Version=zeon-$zeon_revision"
        build_metadata_ldflags="$build_metadata_ldflags -X github.com/sagernet/sing-box/constant.Version=1.13.14-zeon.1-$zeon_revision"
        CGO_LDFLAGS="-O2 -g -s -w -Wl,-z,max-page-size=16384" \
          gomobile bind -v \
          -androidapi=21 \
          -javapkg=com.hiddify.core \
          -libname=hiddify-core \
          -tags="$core_build_tags" \
          -trimpath \
          -ldflags="-w -s -checklinkname=0 -buildid= $build_metadata_ldflags" \
          -target=android \
          -o bin/hiddify-core.aar \
          github.com/sagernet/sing-box/experimental/libbox ./platform/mobile
      )
      cp -f "$core_dir/bin/hiddify-core.aar" "$android_aar"
      ls -lh "$android_aar"
      ;;

    windows)
      require_command make
      require_command x86_64-w64-mingw32-gcc

      echo "Building Windows core DLL, Cronet DLL and CLI..."
      desktop_metadata_ldflags="-X github.com/hiddify/hiddify-core/platform/desktop.buildRevision=$zeon_revision"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.hiddifyCoreTree=$hiddify_core_tree"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.hiddifySingBoxTree=$hiddify_sing_box_tree"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.coreBuildTags=$core_build_tags"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.upstreamVersion=v1.13.14"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.upstreamCommit=25a600db24f7680ad9806ce5427bd0ab8afe1114"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.sourceDirty=false"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.buildTimestampPolicy=SOURCE_DATE_EPOCH=0"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/platform/desktop.buildIDPolicy=empty"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/hiddify/hiddify-core/v2/hcommon/constants.Version=zeon-$zeon_revision"
      desktop_metadata_ldflags="$desktop_metadata_ldflags -X github.com/sagernet/sing-box/constant.Version=1.13.14-zeon.1-$zeon_revision"
      windows_backup_dir="$(mktemp -d)"
      for artifact in hiddify-core.dll libcronet.dll HiddifyCli.exe; do
        if [ -f "$core_dir/bin/$artifact" ]; then
          cp -f "$core_dir/bin/$artifact" "$windows_backup_dir/$artifact"
        fi
      done
      if ! CODE_VERSION="$desktop_metadata_ldflags" make -C "$core_dir" TAGS="$core_build_tags" windows-amd64; then
        for artifact in hiddify-core.dll libcronet.dll HiddifyCli.exe; do
          if [ -f "$windows_backup_dir/$artifact" ]; then
            cp -f "$windows_backup_dir/$artifact" "$core_dir/bin/$artifact"
          fi
        done
        rm -rf "$windows_backup_dir"
        exit 1
      fi
      if [ ! -f "$core_dir/bin/libcronet.dll" ] && [ -f "$windows_backup_dir/libcronet.dll" ]; then
        echo "Cronet DLL was not rebuilt; keeping the previous compatible DLL."
        cp -f "$windows_backup_dir/libcronet.dll" "$core_dir/bin/libcronet.dll"
      fi
      rm -rf "$windows_backup_dir"
      ls -lh \
        "$core_dir/bin/hiddify-core.dll" \
        "$core_dir/bin/libcronet.dll" \
        "$core_dir/bin/HiddifyCli.exe"
      ;;

    linux)
      require_command make
      require_command git

      echo "Preparing Linux Cronet dependency..."
      make -C "$core_dir" TAGS="$core_build_tags" cronet-amd64

      # hiddify-core/Makefile uses this directory as a temporary link location.
      if [ -d "$core_dir/lib" ]; then
        rm -f "$core_dir/lib/hiddify-core.so"
        if ! rmdir "$core_dir/lib"; then
          echo "Temporary directory contains unexpected files: $core_dir/lib" >&2
          exit 1
        fi
      fi

      echo "Building Linux core SO and CLI..."
      make -C "$core_dir" TAGS="$core_build_tags" linux-amd64
      ls -lh \
        "$core_dir/bin/lib/hiddify-core.so" \
        "$core_dir/bin/HiddifyCli"
      ;;
  esac
done

echo
echo "Requested hiddify-core artifacts were rebuilt successfully."
'@
$bashScript = $bashScript -replace "`r`n?", "`n"
$tempBashScript = Join-Path ([System.IO.Path]::GetTempPath()) ("rebuild-hiddify-core-" + [guid]::NewGuid().ToString("N") + ".sh")
[System.IO.File]::WriteAllText($tempBashScript, $bashScript, [System.Text.UTF8Encoding]::new($false))
$escapedTempBashScript = $tempBashScript.Replace("\", "\\")
$wslBashScript = Invoke-Wsl -Arguments @("wslpath", "-a", "-u", $escapedTempBashScript) -CaptureOutput

$bashArguments = @(
    "bash",
    $wslBashScript,
    $wslRepoRoot,
    $skipGoModDownloadValue,
    $skipGomobileInitValue,
    $installPinnedMobileToolsValue,
    $installWebDependenciesValue,
    $smartActiveDebugValue,
    $zeonRevision,
    $hiddifyCoreTree,
    $hiddifySingBoxTree
) + $selectedPlatforms

Write-Host "Repository in WSL: $wslRepoRoot"
Write-Host "Platforms: $($selectedPlatforms -join ', ')"

try {
    Invoke-Wsl -Arguments @("bash", "-n", $wslBashScript)

    if ($DryRun) {
        Write-Host ""
        Write-Host "Dry run: WSL build was not started."
        Write-Host "Command: wsl.exe bash <temporary-build-script> $wslRepoRoot $skipGoModDownloadValue $skipGomobileInitValue $installPinnedMobileToolsValue $installWebDependenciesValue $smartActiveDebugValue <revision> <core-tree> <sing-box-tree> $($selectedPlatforms -join ' ')"
    }
    else {
        Invoke-Wsl -Arguments $bashArguments
    }
}
finally {
    Remove-Item -LiteralPath $tempBashScript -Force -ErrorAction SilentlyContinue
}
