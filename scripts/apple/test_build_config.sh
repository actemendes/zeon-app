#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/build_config.sh"
cd "${PROJECT_ROOT}"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "FAILED: ${description}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

unset FLUTTER_TARGET
assert_equal "${APPLE_PRODUCTION_TARGET}" "$(apple_target_for_mode release)" \
  "release defaults to the production entrypoint"
assert_equal "${APPLE_DEVELOPMENT_TARGET}" "$(apple_target_for_mode debug)" \
  "debug defaults to the development entrypoint"
assert_equal "${APPLE_DEVELOPMENT_TARGET}" "$(apple_target_for_mode profile)" \
  "profile defaults to the development entrypoint"
assert_equal "${APPLE_PRODUCTION_ENVIRONMENT}" "$(apple_environment_for_mode release)" \
  "release artifacts are marked as production"
assert_equal "${APPLE_DEVELOPMENT_ENVIRONMENT}" "$(apple_environment_for_mode profile)" \
  "profile artifacts are marked as development"
assert_equal "${APPLE_GENERAL_RELEASE}" "$(apple_release_for_command macos-artifacts)" \
  "outside-store macOS artifacts keep the custom updater"
assert_equal "${APPLE_APP_STORE_RELEASE}" "$(apple_release_for_command ios-ipa)" \
  "iOS IPA uses the App Store release type"
FLUTTER_TARGET="lib/custom_entrypoint.dart"
assert_equal "${FLUTTER_TARGET}" "$(apple_target_for_mode debug)" \
  "non-release builds preserve an explicit Flutter target"
unset FLUTTER_TARGET

apple_validate_flutter_target release "${APPLE_PRODUCTION_TARGET}" "release target test"
apple_validate_flutter_target debug "${APPLE_DEVELOPMENT_TARGET}" "debug target test"
if apple_validate_flutter_target debug "${APPLE_PRODUCTION_TARGET}" "negative debug production target test" \
  >/dev/null 2>&1; then
  echo "FAILED: debug mode accepted ${APPLE_PRODUCTION_TARGET} with a dev artifact marker" >&2
  exit 1
fi
if apple_validate_flutter_target release "${APPLE_DEVELOPMENT_TARGET}" "negative release target test" \
  >/dev/null 2>&1; then
  echo "FAILED: release target validation accepted ${APPLE_DEVELOPMENT_TARGET}" >&2
  exit 1
fi

for override in \
  "FLUTTER_XCODE_FLUTTER_TARGET=${APPLE_DEVELOPMENT_TARGET}" \
  "FLUTTER_XCODE_FLUTTER_BUILD_MODE=debug" \
  "FLUTTER_XCODE_DART_DEFINES=ZGV2LW92ZXJyaWRl"; do
  if (export "${override}"; apple_validate_protected_xcode_overrides "negative protected override test") \
    >/dev/null 2>&1; then
    echo "FAILED: accepted protected override ${override%%=*}" >&2
    exit 1
  fi
done

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/zeon-apple-config-test.XXXXXX")"
trap 'rm -rf "${fixture_root}"' EXIT
host_plist="${fixture_root}/Runner.app/Info.plist"
extension_plist="${fixture_root}/Runner.app/PlugIns/ZeonPacketTunnel.appex/Info.plist"
mkdir -p "$(dirname "${extension_plist}")"
plutil -create xml1 "${host_plist}"
plutil -create xml1 "${extension_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.3.0' "${host_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 103004' "${host_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string app.zeon.ios' "${host_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.3.0' "${extension_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 103004' "${extension_plist}"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string app.zeon.ios.ZeonPacketTunnel' "${extension_plist}"
apple_validate_embedded_extension_plist \
  "${host_plist}" "${extension_plist}" "matching Packet Tunnel fixture"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 40102' "${extension_plist}"
if apple_validate_embedded_extension_plist \
  "${host_plist}" "${extension_plist}" "negative Packet Tunnel fixture" >/dev/null 2>&1; then
  echo "FAILED: accepted a Packet Tunnel build number that differs from the host" >&2
  exit 1
fi
rm -rf "${fixture_root}"
trap - EXIT

apple_validate_build_config
echo "Apple build configuration checks passed."
