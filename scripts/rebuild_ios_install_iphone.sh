#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/apple/env.sh"
cd "${PROJECT_ROOT}"

IOS_MODE="${IOS_MODE:-profile}"
TARGET="${FLUTTER_TARGET:-lib/main.dart}"
BUNDLE_ID="${BUNDLE_ID:-app.zeon.ios}"
APPLE_RELEASE="${APPLE_RELEASE:-app-store}"
PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1 | tr -d " '\"")"
APP_VERSION="${PUBSPEC_VERSION%%+*}"
APP_BUILD_NUMBER="${PUBSPEC_VERSION#*+}"
if [[ "${APP_BUILD_NUMBER}" == "${PUBSPEC_VERSION}" ]]; then
  APP_BUILD_NUMBER=""
fi

case "${IOS_MODE}" in
  debug|profile|release) ;;
  *)
    echo "Unsupported IOS_MODE=${IOS_MODE}. Use debug, profile, or release." >&2
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

detect_device_id() {
  xcrun devicectl list devices |
    awk '/ connected / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[A-Fa-f0-9-]{36}$/) {
          print $i
          exit
        }
      }
    }'
}

DEVICE_ID="${DEVICE_ID:-$(detect_device_id)}"
if [[ -z "${DEVICE_ID}" ]]; then
  echo "No connected iPhone was detected by devicectl." >&2
  echo "Connect/unlock the iPhone, trust this Mac, or run with DEVICE_ID=<CoreDevice-UUID>." >&2
  exit 1
fi

build_args=(--"${IOS_MODE}" --target "${TARGET}")
build_args+=(--dart-define "release=${APPLE_RELEASE}")
if [[ -n "${APP_VERSION}" ]]; then
  build_args+=(--dart-define "app_version=${APP_VERSION}")
fi
if [[ -n "${APP_BUILD_NUMBER}" ]]; then
  build_args+=(--dart-define "app_build_number=${APP_BUILD_NUMBER}")
fi
if [[ -n "${SENTRY_DSN:-}" ]]; then
  build_args+=(--dart-define "sentry_dsn=${SENTRY_DSN}")
fi

echo "Building iOS ${IOS_MODE} app..."
ensure_generated_sources
flutter build ios "${build_args[@]}"

app_path="${PROJECT_ROOT}/build/ios/iphoneos/Runner.app"
if [[ ! -d "${app_path}" ]]; then
  echo "Build completed, but iOS app was not found at: ${app_path}" >&2
  exit 1
fi

echo "Installing on iPhone: ${DEVICE_ID}"
xcrun devicectl device install app --device "${DEVICE_ID}" "${app_path}"

echo "Installed:"
echo "${app_path}"

if [[ "${LAUNCH_APP:-0}" == "1" ]]; then
  echo "Launching ${BUNDLE_ID} on iPhone..."
  xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing "${BUNDLE_ID}"
fi
