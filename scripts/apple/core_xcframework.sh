#!/usr/bin/env bash

APPLE_GOMOBILE_VERSION="v0.1.11"
APPLE_MACOS_CORE_XCFRAMEWORK="${PROJECT_ROOT}/hiddify-core/bin/HiddifyCore.xcframework"

apple_xcframework_has_platform() {
  local framework="$1"
  local expected_platform="$2"
  local plist="${framework}/Info.plist"
  local index=0
  local platform=""

  [[ -f "${plist}" ]] || return 1

  while platform="$(
    /usr/libexec/PlistBuddy \
      -c "Print :AvailableLibraries:${index}:SupportedPlatform" \
      "${plist}" 2>/dev/null
  )"; do
    if [[ "${platform}" == "${expected_platform}" ]]; then
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

apple_macos_core_binary() {
  local framework="${1:-${APPLE_MACOS_CORE_XCFRAMEWORK}}"
  local candidate=""
  local candidates=(
    "${framework}"/macos-*/HiddifyCore.framework/HiddifyCore
    "${framework}"/macos-*/HiddifyCore.framework/Versions/A/HiddifyCore
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

apple_macos_core_xcframework_is_valid() {
  local framework="${1:-${APPLE_MACOS_CORE_XCFRAMEWORK}}"
  local binary=""
  local architectures=""

  apple_xcframework_has_platform "${framework}" macos || return 1
  binary="$(apple_macos_core_binary "${framework}")" || return 1
  architectures="$(xcrun lipo -archs "${binary}" 2>/dev/null)" || return 1

  case " ${architectures} " in
    *" arm64 "*) ;;
    *) return 1 ;;
  esac
  case " ${architectures} " in
    *" x86_64 "*) ;;
    *) return 1 ;;
  esac
}

apple_gomobile_tool_is_current() {
  local tool="$1"
  local binary="${GOPATH}/bin/${tool}"

  [[ -x "${binary}" ]] || return 1
  go version -m "${binary}" 2>/dev/null |
    grep -Eq "^[[:space:]]*mod[[:space:]]+github.com/sagernet/gomobile[[:space:]]+${APPLE_GOMOBILE_VERSION}([[:space:]]|$)"
}

apple_ensure_gomobile_tools() {
  if apple_gomobile_tool_is_current gomobile && apple_gomobile_tool_is_current gobind; then
    return 0
  fi

  echo "Installing pinned gomobile tools ${APPLE_GOMOBILE_VERSION}..."
  go install "github.com/sagernet/gomobile/cmd/gomobile@${APPLE_GOMOBILE_VERSION}"
  go install "github.com/sagernet/gomobile/cmd/gobind@${APPLE_GOMOBILE_VERSION}"
}

apple_build_macos_core_xcframework() {
  local framework="${APPLE_MACOS_CORE_XCFRAMEWORK}"
  local build_root="${PROJECT_ROOT}/.apple-build/core-xcframework.$$"
  local built_framework="${build_root}/HiddifyCore.xcframework"
  local previous_framework="${framework}.previous.$$"
  local module_cache=""

  command -v go >/dev/null 2>&1 || {
    echo "Go is required to build the macOS HiddifyCore.xcframework." >&2
    return 1
  }
  command -v xcrun >/dev/null 2>&1 || {
    echo "Xcode command line tools are required to build the macOS core." >&2
    return 1
  }

  apple_ensure_gomobile_tools
  module_cache="$(go env GOMODCACHE)"
  mkdir -p "${build_root}" "$(dirname "${framework}")"
  # An interrupted gomobile run can leave generated ObjC bindings behind.
  # gomobile copies into these fixed directories and refuses to overwrite them.
  rm -rf \
    "${PROJECT_ROOT}/hiddify-core/build/ios-arm64/Libbox" \
    "${PROJECT_ROOT}/hiddify-core/build/iossimulator-amd64/Libbox" \
    "${PROJECT_ROOT}/hiddify-core/build/iossimulator-arm64/Libbox" \
    "${PROJECT_ROOT}/hiddify-core/build/macos-amd64/Libbox" \
    "${PROJECT_ROOT}/hiddify-core/build/macos-arm64/Libbox"

  echo "Building universal HiddifyCore.xcframework for iOS and macOS..."
  if ! (
    trap 'rm -rf "${build_root}"' EXIT
    cd "${PROJECT_ROOT}/hiddify-core"
    if ! GOMODCACHE="${module_cache}" go run ./cmd/internal/build_libcore \
      -target ios \
      -output "${built_framework}" \
      -verbose=false; then
      exit 1
    fi
    trap - EXIT
  ); then
    rm -rf "${build_root}"
    echo "Failed to build HiddifyCore.xcframework; the existing artifact was preserved." >&2
    return 1
  fi

  if ! apple_macos_core_xcframework_is_valid "${built_framework}"; then
    rm -rf "${build_root}"
    echo "Generated HiddifyCore.xcframework has no universal macOS slice." >&2
    return 1
  fi

  if [[ -e "${framework}" ]]; then
    mv "${framework}" "${previous_framework}"
  fi
  if ! mv "${built_framework}" "${framework}"; then
    if [[ -e "${previous_framework}" ]]; then
      mv "${previous_framework}" "${framework}"
    fi
    rm -rf "${build_root}"
    echo "Failed to install the generated HiddifyCore.xcframework." >&2
    return 1
  fi

  rm -rf "${previous_framework}" "${build_root}"
  echo "HiddifyCore.xcframework is ready for macOS (arm64 + x86_64)."
}

apple_ensure_macos_core_xcframework() {
  local autobuild="${MACOS_CORE_AUTOBUILD:-1}"

  if apple_macos_core_xcframework_is_valid; then
    return 0
  fi

  if [[ "${autobuild}" != "1" ]]; then
    echo "${APPLE_MACOS_CORE_XCFRAMEWORK} has no universal macOS slice." >&2
    echo "Rerun with MACOS_CORE_AUTOBUILD=1 or build it with:" >&2
    echo "  source scripts/apple/env.sh" >&2
    echo "  (cd hiddify-core && go run ./cmd/internal/build_libcore -target ios)" >&2
    return 1
  fi

  echo "macOS slice is missing from HiddifyCore.xcframework. Rebuilding it once..."
  apple_build_macos_core_xcframework
}
