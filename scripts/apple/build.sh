#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
cd "${PROJECT_ROOT}"

OUT_DIR="${PROJECT_ROOT}/out/apple"
TARGET="${FLUTTER_TARGET:-lib/main.dart}"
BUILD_ARGS=(--release --target "${TARGET}")
if [[ -n "${SENTRY_DSN:-}" ]]; then
  BUILD_ARGS+=(--dart-define "sentry_dsn=${SENTRY_DSN}")
fi

require_file() {
  [[ -e "$1" ]] || {
    echo "Missing $1. Run ./scripts/apple/bootstrap.sh first." >&2
    exit 1
  }
}

ensure_generated_sources() {
  if [[ ! -f lib/features/log/overview/logs_overview_notifier.g.dart ||
        ! -f lib/features/profile/details/profile_details_state.freezed.dart ||
        ! -f lib/gen/translations.g.dart ]]; then
    echo "Generated Dart sources are missing. Regenerating them..."
    flutter pub get --enforce-lockfile
    dart run build_runner build --delete-conflicting-outputs
    dart run slang
  fi
}

doctor() {
  local failed=0
  for command in flutter dart pod go xcodebuild; do
    if command -v "${command}" >/dev/null 2>&1; then
      printf "%-12s %s\n" "${command}" "$(command -v "${command}")"
    else
      echo "Missing command: ${command}" >&2
      failed=1
    fi
  done
  xcodebuild -version
  go version
  pod --version
  require_file hiddify-core/bin/hiddify-core.dylib
  require_file ios/Frameworks/HiddifyCore.xcframework
  if ! flutter --version; then
    echo "Flutter failed to start. Sandboxed shells may block Dart CPU detection." >&2
    failed=1
  else
    flutter doctor -v || echo "Non-Apple Flutter doctor checks are unavailable; Apple tools above are ready."
  fi
  return "${failed}"
}

build_macos_app() {
  require_file hiddify-core/bin/hiddify-core.dylib
  ensure_generated_sources
  flutter build macos "${BUILD_ARGS[@]}"
  mkdir -p "${OUT_DIR}"
  rm -rf "${OUT_DIR}/ZEON.app"
  cp -R build/macos/Build/Products/Release/ZEON.app "${OUT_DIR}/ZEON.app"
  codesign --force --deep --sign - "${OUT_DIR}/ZEON.app"
  codesign --verify --deep --strict --verbose=2 "${OUT_DIR}/ZEON.app"
  echo "${OUT_DIR}/ZEON.app"
}

build_macos_artifacts() {
  build_macos_app
  rm -f "${OUT_DIR}/ZEON-macOS.dmg" "${OUT_DIR}/ZEON-macOS.pkg"

  local dmg_root="${PROJECT_ROOT}/.apple-build/dmg"
  rm -rf "${dmg_root}"
  mkdir -p "${dmg_root}"
  cp -R "${OUT_DIR}/ZEON.app" "${dmg_root}/ZEON.app"
  ln -s /Applications "${dmg_root}/Applications"
  hdiutil create -volname ZEON -srcfolder "${dmg_root}" -ov -format UDZO "${OUT_DIR}/ZEON-macOS.dmg"

  pkgbuild \
    --component "${OUT_DIR}/ZEON.app" \
    --install-location /Applications \
    "${OUT_DIR}/ZEON-macOS.pkg"
  echo "Artifacts: ${OUT_DIR}"
}

build_ios_unsigned() {
  require_file ios/Frameworks/HiddifyCore.xcframework
  ensure_generated_sources
  flutter build ios "${BUILD_ARGS[@]}" --no-codesign
  mkdir -p "${OUT_DIR}"
  rm -rf "${OUT_DIR}/ZEON-iOS-unsigned.app"
  cp -R build/ios/iphoneos/Runner.app "${OUT_DIR}/ZEON-iOS-unsigned.app"
  echo "${OUT_DIR}/ZEON-iOS-unsigned.app"
}

build_ios_ipa() {
  require_file ios/AppleSigning.xcconfig
  require_file ios/Frameworks/HiddifyCore.xcframework
  ensure_generated_sources
  if ! security find-identity -v -p codesigning | grep -qE '[1-9][0-9]* valid identities found'; then
    echo "No Apple code-signing identity is installed in the keychain." >&2
    exit 1
  fi
  flutter build ipa "${BUILD_ARGS[@]}" \
    --export-options-plist ios/exportOptions.plist
  mkdir -p "${OUT_DIR}"
  find build/ios/ipa -maxdepth 1 -name '*.ipa' -exec cp {} "${OUT_DIR}/ZEON-iOS.ipa" \;
  require_file "${OUT_DIR}/ZEON-iOS.ipa"
  echo "${OUT_DIR}/ZEON-iOS.ipa"
}

case "${1:-doctor}" in
  doctor) doctor ;;
  macos-app) build_macos_app ;;
  macos-artifacts) build_macos_artifacts ;;
  ios-unsigned) build_ios_unsigned ;;
  ios-ipa) build_ios_ipa ;;
  *)
    echo "Usage: $0 {doctor|macos-app|macos-artifacts|ios-unsigned|ios-ipa}" >&2
    exit 2
    ;;
esac
