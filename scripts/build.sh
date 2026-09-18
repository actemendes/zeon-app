#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-help}"
shift || true

show_help() {
  cat <<'EOF'
ZEON Apple build entrypoint

Usage: ./scripts/build.sh <action>

  macos-app               Build a macOS .app
  macos-artifacts         Build macOS .app, .dmg, and .pkg
  macos-app-store         Export the macOS App Store package
  macos-app-store-upload  Upload the macOS App Store package
  ios-ipa                 Build a signed iOS IPA
  ios-unsigned            Build an unsigned iOS .app
  ios-device              Build and install on a connected iPhone
  ios-upload              Upload the iOS build
  apple-upload            Upload both Apple applications
  doctor                  Check the Apple build environment

Final artifacts are published only below out/installers/{macos,ios}.
Flutter/Xcode build directories are intermediate and are not distribution paths.
EOF
}

case "${ACTION}" in
  help|-h|--help) show_help ;;
  doctor|apple-upload|macos-app|macos-artifacts|macos-app-store|macos-app-store-upload|ios-unsigned|ios-ipa|ios-device|ios-upload)
    exec "${SCRIPT_DIR}/apple/build.sh" "${ACTION}" "$@"
    ;;
  *)
    echo "Unknown build action: ${ACTION}" >&2
    show_help >&2
    exit 2
    ;;
esac
