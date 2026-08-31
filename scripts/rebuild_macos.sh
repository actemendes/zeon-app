#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/apple/env.sh"
source "${SCRIPT_DIR}/apple/build_config.sh"
source "${SCRIPT_DIR}/apple/core_xcframework.sh"
cd "${PROJECT_ROOT}"

BUILD_MODE="${BUILD_MODE:-debug}"
APP_NAME="${APP_NAME:-ZEON.app}"
APPLE_RELEASE="${APPLE_RELEASE:-${APPLE_GENERAL_RELEASE}}"

case "${BUILD_MODE}" in
  debug|profile|release) ;;
  *)
    echo "Unsupported BUILD_MODE=${BUILD_MODE}. Use debug, profile, or release." >&2
    exit 2
    ;;
esac

TARGET="$(apple_target_for_mode "${BUILD_MODE}")"
BUILD_ENVIRONMENT="$(apple_environment_for_mode "${BUILD_MODE}")"
apple_validate_build_config
apple_validate_flutter_target "${BUILD_MODE}" "${TARGET}" "macOS local build"

ensure_generated_sources() {
  if [[ ! -f lib/features/log/overview/logs_overview_notifier.g.dart ||
        ! -f lib/features/profile/details/profile_details_state.freezed.dart ||
        ! -f lib/gen/translations.g.dart ]]; then
    echo "Generated Dart sources are missing. Regenerating..."
    flutter pub get --enforce-lockfile
    dart run build_runner build --delete-conflicting-outputs
    dart run slang
  fi
}

build_args=(--"${BUILD_MODE}" --target "${TARGET}")
build_args+=(--dart-define "release=${APPLE_RELEASE}")
if [[ -n "${SENTRY_DSN:-}" ]]; then
  build_args+=(--dart-define "sentry_dsn=${SENTRY_DSN}")
fi

echo "Building macOS ${BUILD_MODE} app..."
apple_ensure_macos_core_xcframework
ensure_generated_sources
flutter build macos "${build_args[@]}"

configuration="$(tr '[:lower:]' '[:upper:]' <<< "${BUILD_MODE:0:1}")${BUILD_MODE:1}"
app_path="${PROJECT_ROOT}/build/macos/Build/Products/${configuration}/${APP_NAME}"

if [[ ! -d "${app_path}" ]]; then
  echo "Build completed, but app was not found at: ${app_path}" >&2
  exit 1
fi
apple_validate_built_info_plist \
  "${app_path}/Contents/Info.plist" \
  "macOS local app" \
  "${BUILD_ENVIRONMENT}"

echo "macOS app built:"
echo "${app_path}"

if [[ "${OPEN_APP:-0}" == "1" ]]; then
  echo "Opening ${app_path}..."
  open "${app_path}"
fi
