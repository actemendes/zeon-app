#!/usr/bin/env bash

# Shared, non-secret Apple build invariants. Keep signing credentials in the
# ignored AppleSigning.xcconfig files; these values must be identical on every
# build machine.
APPLE_PRODUCTION_TARGET="lib/main_prod.dart"
APPLE_DEVELOPMENT_TARGET="lib/main.dart"
APPLE_SERVICE_IDENTIFIER="com.zeon.app"
APPLE_PRODUCTION_ENVIRONMENT="prod"
APPLE_DEVELOPMENT_ENVIRONMENT="dev"
APPLE_APP_STORE_RELEASE="app-store"
APPLE_GENERAL_RELEASE="general"

apple_release_for_command() {
  local command="$1"

  case "${command}" in
    macos-app|macos-artifacts)
      printf '%s\n' "${APPLE_GENERAL_RELEASE}"
      ;;
    *)
      printf '%s\n' "${APPLE_APP_STORE_RELEASE}"
      ;;
  esac
}

apple_validate_protected_xcode_overrides() {
  local context="${1:-Apple build}"
  local variable_name
  local variable_value
  local protected_variables=(
    FLUTTER_XCODE_FLUTTER_TARGET
    FLUTTER_XCODE_FLUTTER_BUILD_MODE
    FLUTTER_XCODE_DART_DEFINES
    FLUTTER_XCODE_SERVICE_IDENTIFIER
    FLUTTER_XCODE_ZEON_FLUTTER_ENVIRONMENT
    FLUTTER_XCODE_FLUTTER_BUILD_NAME
    FLUTTER_XCODE_FLUTTER_BUILD_NUMBER
    FLUTTER_XCODE_MARKETING_VERSION
    FLUTTER_XCODE_CURRENT_PROJECT_VERSION
  )

  for variable_name in "${protected_variables[@]}"; do
    variable_value="${!variable_name-}"
    if [[ -n "${variable_value}" ]]; then
      echo "${context}: ${variable_name} is a protected Xcode override and must be unset." >&2
      return 1
    fi
  done
}

apple_target_for_mode() {
  local build_mode="$1"

  if [[ -n "${FLUTTER_TARGET:-}" ]]; then
    printf '%s\n' "${FLUTTER_TARGET}"
  elif [[ "${build_mode}" == "release" ]]; then
    printf '%s\n' "${APPLE_PRODUCTION_TARGET}"
  else
    printf '%s\n' "${APPLE_DEVELOPMENT_TARGET}"
  fi
}

apple_environment_for_mode() {
  local build_mode="$1"
  if [[ "${build_mode}" == "release" ]]; then
    printf '%s\n' "${APPLE_PRODUCTION_ENVIRONMENT}"
  else
    printf '%s\n' "${APPLE_DEVELOPMENT_ENVIRONMENT}"
  fi
}

apple_resolve_target_path() {
  local target="$1"
  local target_path
  if [[ "${target}" == /* ]]; then
    target_path="${target}"
  else
    target_path="${PROJECT_ROOT}/${target}"
  fi

  local target_dir
  target_dir="$(cd "$(dirname "${target_path}")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "${target_dir}" "$(basename "${target_path}")"
}

apple_validate_flutter_target() {
  local build_mode="$1"
  local target="$2"
  local context="${3:-Apple build}"
  local resolved_target
  local production_target

  resolved_target="$(apple_resolve_target_path "${target}")" || {
    echo "${context}: Flutter target directory does not exist: ${target}" >&2
    return 1
  }
  [[ -f "${resolved_target}" ]] || {
    echo "${context}: Flutter target does not exist: ${target}" >&2
    return 1
  }

  production_target="$(apple_resolve_target_path "${APPLE_PRODUCTION_TARGET}")"
  if [[ "${build_mode}" != "release" ]]; then
    if [[ "${resolved_target}" == "${production_target}" ]]; then
      echo "${context}: ${APPLE_PRODUCTION_TARGET} requires release mode so the artifact marker stays truthful." >&2
      return 1
    fi
    return 0
  fi

  if [[ "${resolved_target}" != "${production_target}" ]]; then
    echo "${context}: release builds must use ${APPLE_PRODUCTION_TARGET}; got ${target}." >&2
    echo "Use debug/profile mode for ${APPLE_DEVELOPMENT_TARGET}." >&2
    return 1
  fi
}

apple_xcconfig_value() {
  local config_file="$1"
  local wanted_key="$2"

  awk -F= -v wanted_key="${wanted_key}" '
    /^[[:space:]]*(\/\/|#)/ { next }
    {
      key = $1
      gsub(/[[:space:]]/, "", key)
      if (key == wanted_key) {
        value = $0
        sub(/^[^=]*=/, "", value)
        sub(/^[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
      }
    }
    END { print value }
  ' "${config_file}"
}

apple_validate_build_config() {
  local ios_config="${PROJECT_ROOT}/ios/Base.xcconfig"
  local macos_config="${PROJECT_ROOT}/macos/Runner/Configs/AppInfo.xcconfig"
  local dart_channel_file="${PROJECT_ROOT}/lib/zeoncore/core_interface/core_interface_mobile.dart"
  local ios_project_file="${PROJECT_ROOT}/ios/Runner.xcodeproj/project.pbxproj"
  local macos_project_file="${PROJECT_ROOT}/macos/Runner.xcodeproj/project.pbxproj"
  local ios_extension_info="${PROJECT_ROOT}/ios/ZeonPacketTunnel/Info.plist"
  local ios_extension_config="${PROJECT_ROOT}/ios/ZeonPacketTunnel/ZeonPacketTunnel.xcconfig"
  local ios_export_options="${PROJECT_ROOT}/ios/exportOptions.plist"
  local macos_export_options="${PROJECT_ROOT}/macos/exportOptions.plist"
  local ios_service_identifier
  local macos_service_identifier
  local ios_default_environment
  local macos_default_environment

  apple_validate_protected_xcode_overrides "Apple build configuration"

  ios_service_identifier="$(apple_xcconfig_value "${ios_config}" SERVICE_IDENTIFIER)"
  macos_service_identifier="$(apple_xcconfig_value "${macos_config}" SERVICE_IDENTIFIER)"
  ios_default_environment="$(apple_xcconfig_value "${ios_config}" ZEON_FLUTTER_ENVIRONMENT)"
  macos_default_environment="$(apple_xcconfig_value "${macos_config}" ZEON_FLUTTER_ENVIRONMENT)"

  if [[ "${ios_service_identifier}" != "${APPLE_SERVICE_IDENTIFIER}" ]]; then
    echo "${ios_config}: SERVICE_IDENTIFIER must be ${APPLE_SERVICE_IDENTIFIER}; got ${ios_service_identifier:-<empty>}." >&2
    return 1
  fi
  if [[ "${macos_service_identifier}" != "${APPLE_SERVICE_IDENTIFIER}" ]]; then
    echo "${macos_config}: SERVICE_IDENTIFIER must be ${APPLE_SERVICE_IDENTIFIER}; got ${macos_service_identifier:-<empty>}." >&2
    return 1
  fi
  if [[ "${ios_default_environment}" != "${APPLE_DEVELOPMENT_ENVIRONMENT}" ||
        "${macos_default_environment}" != "${APPLE_DEVELOPMENT_ENVIRONMENT}" ]]; then
    echo "Apple xcconfig defaults must mark non-release builds as ${APPLE_DEVELOPMENT_ENVIRONMENT}." >&2
    return 1
  fi
  if ! grep -Fq "static const channelPrefix = \"${APPLE_SERVICE_IDENTIFIER}\";" "${dart_channel_file}"; then
    echo "${dart_channel_file}: channelPrefix must match ${APPLE_SERVICE_IDENTIFIER}." >&2
    return 1
  fi
  if ! grep -Eq '(lazyBootstrap\(widgetsBinding,[[:space:]]*|runZeonApp\()[[:space:]]*Environment\.prod\)' \
    "${PROJECT_ROOT}/${APPLE_PRODUCTION_TARGET}"; then
    echo "${APPLE_PRODUCTION_TARGET}: expected Environment.prod entrypoint." >&2
    return 1
  fi
  if ! grep -Eq '(lazyBootstrap\(widgetsBinding,[[:space:]]*|runZeonApp\()[[:space:]]*Environment\.dev\)' \
    "${PROJECT_ROOT}/${APPLE_DEVELOPMENT_TARGET}"; then
    echo "${APPLE_DEVELOPMENT_TARGET}: expected Environment.dev entrypoint." >&2
    return 1
  fi
  if ! grep -Fq "FLUTTER_TARGET = ${APPLE_PRODUCTION_TARGET};" "${ios_project_file}"; then
    echo "${ios_project_file}: Runner Release must pin ${APPLE_PRODUCTION_TARGET}." >&2
    return 1
  fi
  if ! grep -Fq "FLUTTER_TARGET = ${APPLE_PRODUCTION_TARGET};" "${macos_project_file}"; then
    echo "${macos_project_file}: Runner Release must pin ${APPLE_PRODUCTION_TARGET}." >&2
    return 1
  fi
  if ! grep -Fq "ZEON_FLUTTER_ENVIRONMENT = ${APPLE_PRODUCTION_ENVIRONMENT};" "${ios_project_file}"; then
    echo "${ios_project_file}: Runner Release must mark the production environment." >&2
    return 1
  fi
  if ! grep -Fq "ZEON_FLUTTER_ENVIRONMENT = ${APPLE_PRODUCTION_ENVIRONMENT};" "${macos_project_file}"; then
    echo "${macos_project_file}: Runner Release must mark the production environment." >&2
    return 1
  fi
  if ! grep -Fq '<string>$(FLUTTER_BUILD_NAME)</string>' "${ios_extension_info}" ||
     ! grep -Fq '<string>$(FLUTTER_BUILD_NUMBER)</string>' "${ios_extension_info}"; then
    echo "${ios_extension_info}: Packet Tunnel must inherit the Flutter version and build number." >&2
    return 1
  fi
  if ! grep -Fq '#include "../Flutter/Generated.xcconfig"' "${ios_extension_config}" ||
     ! grep -Fq '#include "../Base.xcconfig"' "${ios_extension_config}"; then
    echo "${ios_extension_config}: Packet Tunnel must include generated Flutter metadata and shared Apple settings." >&2
    return 1
  fi
  if [[ "$(grep -Fc 'baseConfigurationReference = A1B2C3D4E5F60718293A4B5C /* ZeonPacketTunnel.xcconfig */;' "${ios_project_file}")" -ne 3 ]]; then
    echo "${ios_project_file}: all Packet Tunnel configurations must use ZeonPacketTunnel.xcconfig." >&2
    return 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :manageAppVersionAndBuildNumber' "${ios_export_options}" 2>/dev/null || true)" != "false" ||
        "$(/usr/libexec/PlistBuddy -c 'Print :manageAppVersionAndBuildNumber' "${macos_export_options}" 2>/dev/null || true)" != "false" ]]; then
    echo "Apple export options must keep manageAppVersionAndBuildNumber=false for reproducible host/extension versions." >&2
    return 1
  fi
}

apple_validate_embedded_extension_plist() {
  local host_plist="$1"
  local extension_plist="$2"
  local context="$3"
  local host_version
  local host_build_number
  local host_bundle_id
  local extension_version
  local extension_build_number
  local extension_bundle_id

  [[ -f "${extension_plist}" ]] || {
    echo "${context}: embedded Packet Tunnel Info.plist not found: ${extension_plist}" >&2
    return 1
  }

  host_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${host_plist}" 2>/dev/null || true)"
  host_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${host_plist}" 2>/dev/null || true)"
  host_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${host_plist}" 2>/dev/null || true)"
  extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${extension_plist}" 2>/dev/null || true)"
  extension_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${extension_plist}" 2>/dev/null || true)"
  extension_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${extension_plist}" 2>/dev/null || true)"

  if [[ -z "${extension_version}" || "${extension_version}" != "${host_version}" ]]; then
    echo "${context}: Packet Tunnel version must match host ${host_version:-<empty>}; got ${extension_version:-<empty>}." >&2
    return 1
  fi
  if [[ -z "${extension_build_number}" || "${extension_build_number}" != "${host_build_number}" ]]; then
    echo "${context}: Packet Tunnel build number must match host ${host_build_number:-<empty>}; got ${extension_build_number:-<empty>}." >&2
    return 1
  fi
  if [[ -z "${host_bundle_id}" || "${extension_bundle_id}" != "${host_bundle_id}.ZeonPacketTunnel" ]]; then
    echo "${context}: Packet Tunnel bundle id must be ${host_bundle_id:-<host bundle id>}.ZeonPacketTunnel; got ${extension_bundle_id:-<empty>}." >&2
    return 1
  fi
}

apple_validate_built_info_plist() {
  local plist="$1"
  local context="${2:-Apple artifact}"
  local expected_environment="$3"
  local service_identifier
  local flutter_environment
  local bundle_version
  local bundle_build_number
  local pubspec_version
  local expected_version
  local expected_build_number
  local extension_plist

  [[ -f "${plist}" ]] || {
    echo "${context}: Info.plist not found: ${plist}" >&2
    return 1
  }
  service_identifier="$(/usr/libexec/PlistBuddy -c 'Print :SERVICE_IDENTIFIER' "${plist}" 2>/dev/null || true)"
  if [[ "${service_identifier}" != "${APPLE_SERVICE_IDENTIFIER}" ]]; then
    echo "${context}: built SERVICE_IDENTIFIER must be ${APPLE_SERVICE_IDENTIFIER}; got ${service_identifier:-<empty>}." >&2
    return 1
  fi
  flutter_environment="$(/usr/libexec/PlistBuddy -c 'Print :ZEON_FLUTTER_ENVIRONMENT' "${plist}" 2>/dev/null || true)"
  if [[ "${flutter_environment}" != "${expected_environment}" ]]; then
    echo "${context}: built ZEON_FLUTTER_ENVIRONMENT must be ${expected_environment}; got ${flutter_environment:-<empty>}." >&2
    return 1
  fi

  pubspec_version="$(sed -n 's/^version:[[:space:]]*//p' "${PROJECT_ROOT}/pubspec.yaml" | head -n 1 | tr -d " '\"")"
  expected_version="${pubspec_version%%+*}"
  expected_build_number="${pubspec_version#*+}"
  if [[ "${expected_build_number}" == "${pubspec_version}" ]]; then
    expected_build_number=""
  fi
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null || true)"
  bundle_build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2>/dev/null || true)"
  if [[ -n "${expected_version}" && "${bundle_version}" != "${expected_version}" ]]; then
    echo "${context}: CFBundleShortVersionString must be ${expected_version}; got ${bundle_version:-<empty>}." >&2
    return 1
  fi
  if [[ -n "${expected_build_number}" && "${bundle_build_number}" != "${expected_build_number}" ]]; then
    echo "${context}: CFBundleVersion must be ${expected_build_number}; got ${bundle_build_number:-<empty>}." >&2
    return 1
  fi

  if [[ "${plist}" == */Contents/Info.plist ]]; then
    extension_plist="${plist%/Info.plist}/PlugIns/ZeonPacketTunnel.appex/Contents/Info.plist"
  else
    extension_plist="${plist%/Info.plist}/PlugIns/ZeonPacketTunnel.appex/Info.plist"
  fi
  apple_validate_embedded_extension_plist "${plist}" "${extension_plist}" "${context}"
}
