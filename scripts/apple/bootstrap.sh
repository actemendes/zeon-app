#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/core_xcframework.sh"
cd "${PROJECT_ROOT}"

FLUTTER_VERSION="3.38.5"
FLUTTER_SHA256="d3cf518d5deebb183da74e12a5639659d4728824097c1d0d09b144f227b7b502"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_${FLUTTER_VERSION}-stable.zip"
GO_VERSION="1.25.6"
GO_SHA256="e2b5b237f5c262931b8e280ac4b8363f156e19bfad5270c099998932819670b7"
GO_URL="https://go.dev/dl/go${GO_VERSION}.darwin-amd64.tar.gz"

mkdir -p "${TOOLCHAINS_DIR}" "${PUB_CACHE}" "${GEM_HOME}" "${GOPATH}"

download() {
  local url="$1"
  local output="$2"
  local sha256="$3"
  if [[ ! -f "${output}" ]]; then
    curl -fL --retry 3 --progress-bar "${url}" -o "${output}"
  fi
  echo "${sha256}  ${output}" | shasum -a 256 -c -
}

install_gem() {
  local name="$1"
  local version="$2"
  shift 2
  gem install "${name}" --version "${version}" --no-document \
    --install-dir "${GEM_HOME}" "$@"
}

install_cocoapods() {
  if command -v pod >/dev/null 2>&1 && pod --version >/dev/null 2>&1; then
    return
  fi

  # macOS still ships Ruby 2.6. Pin transitive dependencies that remain
  # compatible with it. Newer Rubies can use RubyGems' normal resolver.
  if ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.0")'; then
    install_gem cocoapods 1.16.2
    return
  fi

  local specs=(
    "public_suffix:4.0.7"
    "addressable:2.9.0"
    "ruby-macho:2.5.1"
    "nap:1.1.0"
    "gh_inspector:1.1.3"
    "fourflusher:2.3.1"
    "escape:0.0.4"
    "colored2:3.1.2"
    "rexml:3.4.4"
    "nanaimo:0.4.0"
    "claide:1.1.0"
    "CFPropertyList:3.0.9"
    "atomos:0.1.3"
    "xcodeproj:1.27.0"
    "molinillo:0.8.0"
    "cocoapods-try:1.2.0"
    "netrc:0.11.0"
    "cocoapods-trunk:1.6.0"
    "cocoapods-search:1.0.1"
    "cocoapods-plugins:1.0.0"
    "cocoapods-downloader:2.1"
    "cocoapods-deintegrate:1.0.5"
    "logger:1.7.0"
    "ffi:1.17.2"
    "ethon:0.16.0"
    "typhoeus:1.4.1"
    "concurrent-ruby:1.3.5"
    "i18n:1.14.7"
    "minitest:5.20.0"
    "tzinfo:2.0.6"
    "zeitwerk:2.6.18"
    "activesupport:6.1.7.10"
    "algoliasearch:1.27.5"
    "fuzzy_match:2.0.4"
    "httpclient:2.8.3"
  )
  local spec
  for spec in "${specs[@]}"; do
    install_gem "${spec%%:*}" "${spec#*:}" --ignore-dependencies
  done
  install_gem cocoapods-core 1.16.2 --ignore-dependencies
  install_gem cocoapods 1.16.2 --ignore-dependencies
}

if [[ ! -x "${TOOLCHAINS_DIR}/flutter/bin/flutter" ]]; then
  flutter_archive="${TOOLCHAINS_DIR}/flutter-${FLUTTER_VERSION}.zip"
  download "${FLUTTER_URL}" "${flutter_archive}" "${FLUTTER_SHA256}"
  rm -rf "${TOOLCHAINS_DIR}/flutter"
  ditto -x -k "${flutter_archive}" "${TOOLCHAINS_DIR}"
fi

if [[ ! -x "${TOOLCHAINS_DIR}/go/bin/go" ]]; then
  go_archive="${TOOLCHAINS_DIR}/go-${GO_VERSION}.tar.gz"
  download "${GO_URL}" "${go_archive}" "${GO_SHA256}"
  rm -rf "${TOOLCHAINS_DIR}/go"
  tar -xzf "${go_archive}" -C "${TOOLCHAINS_DIR}"
fi

mkdir -p hiddify-core/bin ios/Frameworks
if [[ ! -f hiddify-core/bin/hiddify-core.dylib ]]; then
  curl -fL --retry 3 \
    "https://github.com/hiddify/hiddify-next-core/releases/download/v4.1.0/hiddify-lib-macos.tar.gz" |
    tar xz -C hiddify-core/bin
fi
if [[ ! -d ios/Frameworks/HiddifyCore.xcframework ]]; then
  rm -rf ios/Frameworks/HiddifyCore.xcframework
  curl -fL --retry 3 \
    "https://github.com/hiddify/hiddify-next-core/releases/download/v4.1.0/hiddify-lib-ios.tar.gz" |
    tar xz -C ios/Frameworks
fi
apple_ensure_macos_core_xcframework

install_cocoapods

if ! flutter config --enable-ios --enable-macos-desktop --no-analytics; then
  echo >&2
  echo "Flutter could not start in the current shell." >&2
  echo "If this is a sandboxed shell, rerun 'make apple-setup' in Terminal." >&2
  exit 1
fi
flutter precache --ios --macos

if ! command -v fastforge >/dev/null 2>&1; then
  dart pub global activate fastforge
fi

flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart run slang

(cd macos && pod install)
(cd ios && pod install)

echo
echo "Apple environment is ready."
echo "Run: source scripts/apple/env.sh"
echo "Then: make apple-doctor"
