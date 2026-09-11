#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/apple/env.sh"
cd "${PROJECT_ROOT}"

BUILD_MODE="${BUILD_MODE:-debug}"
TARGET="${FLUTTER_TARGET:-lib/main.dart}"
APP_NAME="${APP_NAME:-ZEON.app}"
APPLE_RELEASE="${APPLE_RELEASE:-app-store}"

case "${BUILD_MODE}" in
  debug|profile|release) ;;
  *)
    echo "Unsupported BUILD_MODE=${BUILD_MODE}. Use debug, profile, or release." >&2
    exit 2
    ;;
esac

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
ensure_generated_sources
flutter build macos "${build_args[@]}"

configuration="$(tr '[:lower:]' '[:upper:]' <<< "${BUILD_MODE:0:1}")${BUILD_MODE:1}"
app_path="${PROJECT_ROOT}/build/macos/Build/Products/${configuration}/${APP_NAME}"

if [[ ! -d "${app_path}" ]]; then
  echo "Build completed, but app was not found at: ${app_path}" >&2
  exit 1
fi

echo "macOS app built:"
echo "${app_path}"

if [[ "${OPEN_APP:-0}" == "1" ]]; then
  echo "Opening ${app_path}..."
  open "${app_path}"
fi
