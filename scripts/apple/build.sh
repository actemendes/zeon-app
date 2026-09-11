#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
cd "${PROJECT_ROOT}"

OUT_DIR="${PROJECT_ROOT}/out/apple"
TARGET="${FLUTTER_TARGET:-lib/main.dart}"
APPLE_RELEASE="${APPLE_RELEASE:-app-store}"
MACOS_EXPORT_DESTINATION="${MACOS_EXPORT_DESTINATION:-export}"
IOS_UPLOAD_SKIP_BUILD="${IOS_UPLOAD_SKIP_BUILD:-0}"
PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | tr -d " '\"")"
APP_VERSION="${PUBSPEC_VERSION%%+*}"
APP_BUILD_NUMBER="${PUBSPEC_VERSION#*+}"
if [[ "${APP_BUILD_NUMBER}" == "${PUBSPEC_VERSION}" ]]; then
  APP_BUILD_NUMBER=""
fi
BUILD_ARGS=(--release --target "${TARGET}")
BUILD_ARGS+=(--dart-define "release=${APPLE_RELEASE}")
if [[ -n "${APP_VERSION}" ]]; then
  BUILD_ARGS+=(--dart-define "app_version=${APP_VERSION}")
fi
if [[ -n "${APP_BUILD_NUMBER}" ]]; then
  BUILD_ARGS+=(--dart-define "app_build_number=${APP_BUILD_NUMBER}")
fi
if [[ -n "${SENTRY_DSN:-}" ]]; then
  BUILD_ARGS+=(--dart-define "sentry_dsn=${SENTRY_DSN}")
fi

XCODEBUILD_AUTH_ARGS=()
if [[ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ||
      -n "${APP_STORE_CONNECT_API_KEY_ID:-}" ||
      -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
  if [[ -z "${APP_STORE_CONNECT_API_KEY_PATH:-}" ||
        -z "${APP_STORE_CONNECT_API_KEY_ID:-}" ||
        -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    echo "Set APP_STORE_CONNECT_API_KEY_PATH, APP_STORE_CONNECT_API_KEY_ID, and APP_STORE_CONNECT_API_ISSUER_ID together." >&2
    exit 2
  fi
  XCODEBUILD_AUTH_ARGS+=(
    -authenticationKeyPath "${APP_STORE_CONNECT_API_KEY_PATH}"
    -authenticationKeyID "${APP_STORE_CONNECT_API_KEY_ID}"
    -authenticationKeyIssuerID "${APP_STORE_CONNECT_API_ISSUER_ID}"
  )
fi

require_file() {
  [[ -e "$1" ]] || {
    echo "Missing $1. Run ./scripts/apple/bootstrap.sh first." >&2
    exit 1
  }
}

set_plist_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}"
  else
    /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist}"
  fi
}

run_xcodebuild() {
  if ((${#XCODEBUILD_AUTH_ARGS[@]})); then
    xcodebuild "$@" "${XCODEBUILD_AUTH_ARGS[@]}"
  else
    xcodebuild "$@"
  fi
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

build_macos_app_store() {
  case "${MACOS_EXPORT_DESTINATION}" in
    export|upload) ;;
    *)
      echo "Unsupported MACOS_EXPORT_DESTINATION=${MACOS_EXPORT_DESTINATION}. Use export or upload." >&2
      exit 2
      ;;
  esac

  require_file macos/Runner/Configs/AppleSigning.xcconfig
  require_file macos/exportOptions.plist
  require_file hiddify-core/bin/HiddifyCore.xcframework
  ensure_generated_sources

  flutter build macos "${BUILD_ARGS[@]}" --config-only

  mkdir -p "${OUT_DIR}" "${PROJECT_ROOT}/.apple-build"
  local archive_path="${PROJECT_ROOT}/build/macos/archive/ZEON.xcarchive"
  local export_path="${OUT_DIR}/ZEON-macOS-app-store"
  local export_options="${PROJECT_ROOT}/.apple-build/macos-exportOptions.plist"
  rm -rf "${archive_path}" "${export_path}"
  cp macos/exportOptions.plist "${export_options}"
  set_plist_string "${export_options}" destination "${MACOS_EXPORT_DESTINATION}"
  if [[ -n "${MACOS_EXPORT_TEAM_ID:-}" ]]; then
    set_plist_string "${export_options}" teamID "${MACOS_EXPORT_TEAM_ID}"
  fi

  run_xcodebuild \
    -workspace macos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    -allowProvisioningUpdates \
    archive

  run_xcodebuild \
    -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist "${export_options}" \
    -allowProvisioningUpdates

  echo "Archive: ${archive_path}"
  echo "Export: ${export_path}"
  if [[ "${MACOS_EXPORT_DESTINATION}" == "export" ]]; then
    find "${export_path}" -maxdepth 2 -type f -print
  fi
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

upload_ios_app_store() {
  require_file ios/AppleSigning.xcconfig
  require_file ios/exportOptions.plist
  require_file ios/Frameworks/HiddifyCore.xcframework
  if ! security find-identity -v -p codesigning | grep -qE '[1-9][0-9]* valid identities found'; then
    echo "No Apple code-signing identity is installed in the keychain." >&2
    exit 1
  fi

  if [[ "${IOS_UPLOAD_SKIP_BUILD}" != "1" ]]; then
    build_ios_ipa
  else
    ensure_generated_sources
  fi

  local archive_path="${PROJECT_ROOT}/build/ios/archive/Runner.xcarchive"
  require_file "${archive_path}"

  mkdir -p "${OUT_DIR}" "${PROJECT_ROOT}/.apple-build"
  local export_path="${OUT_DIR}/ZEON-iOS-upload"
  local export_options="${PROJECT_ROOT}/.apple-build/ios-exportOptions-upload.plist"
  rm -rf "${export_path}"
  cp ios/exportOptions.plist "${export_options}"
  set_plist_string "${export_options}" destination upload
  if [[ -n "${IOS_EXPORT_TEAM_ID:-}" ]]; then
    set_plist_string "${export_options}" teamID "${IOS_EXPORT_TEAM_ID}"
  fi

  run_xcodebuild \
    -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist "${export_options}" \
    -allowProvisioningUpdates
}

upload_macos_app_store() {
  MACOS_EXPORT_DESTINATION=upload build_macos_app_store
}

upload_all_app_store() {
  upload_ios_app_store
  upload_macos_app_store
}

case "${1:-doctor}" in
  doctor) doctor ;;
  apple-upload) upload_all_app_store ;;
  macos-app) build_macos_app ;;
  macos-artifacts) build_macos_artifacts ;;
  macos-app-store) build_macos_app_store ;;
  macos-app-store-upload) upload_macos_app_store ;;
  ios-unsigned) build_ios_unsigned ;;
  ios-ipa) build_ios_ipa ;;
  ios-upload) upload_ios_app_store ;;
  *)
    echo "Usage: $0 {doctor|apple-upload|macos-app|macos-artifacts|macos-app-store|macos-app-store-upload|ios-unsigned|ios-ipa|ios-upload}" >&2
    exit 2
    ;;
esac
