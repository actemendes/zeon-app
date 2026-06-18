[CmdletBinding()]
param(
    [ValidateSet("android", "windows", "linux")]
    [string[]]$Platform = @("windows"),

    [string]$WslDistribution,

    [switch]$SkipGoModDownload,

    [switch]$SkipGomobileInit,

    [switch]$InstallWebDependencies,

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

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$coreDir = Join-Path $repoRoot "hiddify-core"

Assert-Command "wsl.exe"

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
$installWebDependenciesValue = if ($InstallWebDependencies) { "1" } else { "0" }
$selectedPlatforms = @($Platform | Select-Object -Unique)

$bashScript = @'
set -euo pipefail

repo_root="$1"
skip_go_mod_download="$2"
skip_gomobile_init="$3"
install_web_dependencies="$4"
shift 4
platforms=("$@")

core_dir="$repo_root/hiddify-core"
android_aar="$repo_root/android/app/libs/hiddify-core.aar"

export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
export GOPATH="${GOPATH:-$(go env GOPATH 2>/dev/null || true)}"
if [ -n "$GOPATH" ]; then
  export PATH="$PATH:$GOPATH/bin"
fi

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

require_command go
require_directory "$core_dir"

required_go_version="$(awk '$1 == "go" { print $2; exit }' "$core_dir/go.mod")"
if [ -n "$required_go_version" ]; then
  export GOTOOLCHAIN="go$required_go_version"
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

      echo "Installing pinned gomobile tools..."
      go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.11
      go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.11

      if [ "$skip_gomobile_init" != "1" ]; then
        echo "Initializing gomobile..."
        gomobile init -v
      fi

      echo "Building Android AAR..."
      mkdir -p "$core_dir/bin" "$(dirname "$android_aar")"
      (
        cd "$core_dir"
        CGO_LDFLAGS="-O2 -g -s -w -Wl,-z,max-page-size=16384" \
          gomobile bind -v \
          -androidapi=21 \
          -javapkg=com.hiddify.core \
          -libname=hiddify-core \
          -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,badlinkname,tfogo_checklinkname0,with_naive_outbound,with_conntrack \
          -trimpath \
          -ldflags="-w -s -checklinkname=0 -buildid=" \
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
      windows_backup_dir="$(mktemp -d)"
      for artifact in hiddify-core.dll libcronet.dll HiddifyCli.exe; do
        if [ -f "$core_dir/bin/$artifact" ]; then
          cp -f "$core_dir/bin/$artifact" "$windows_backup_dir/$artifact"
        fi
      done
      if ! make -C "$core_dir" windows-amd64; then
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
      make -C "$core_dir" cronet-amd64

      # hiddify-core/Makefile uses this directory as a temporary link location.
      if [ -d "$core_dir/lib" ]; then
        rm -f "$core_dir/lib/hiddify-core.so"
        if ! rmdir "$core_dir/lib"; then
          echo "Temporary directory contains unexpected files: $core_dir/lib" >&2
          exit 1
        fi
      fi

      echo "Building Linux core SO and CLI..."
      make -C "$core_dir" linux-amd64
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
    $installWebDependenciesValue
) + $selectedPlatforms

Write-Host "Repository in WSL: $wslRepoRoot"
Write-Host "Platforms: $($selectedPlatforms -join ', ')"

try {
    Invoke-Wsl -Arguments @("bash", "-n", $wslBashScript)

    if ($DryRun) {
        Write-Host ""
        Write-Host "Dry run: WSL build was not started."
        Write-Host "Command: wsl.exe bash <temporary-build-script> $wslRepoRoot $skipGoModDownloadValue $skipGomobileInitValue $installWebDependenciesValue $($selectedPlatforms -join ' ')"
    }
    else {
        Invoke-Wsl -Arguments $bashArguments
    }
}
finally {
    Remove-Item -LiteralPath $tempBashScript -Force -ErrorAction SilentlyContinue
}
