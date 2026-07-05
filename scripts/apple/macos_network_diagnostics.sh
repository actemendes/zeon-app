#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
cd "${PROJECT_ROOT}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_ROOT="${OUT_ROOT:-${PROJECT_ROOT}/out/diagnostics}"
OUT_DIR="${OUT_DIR:-${OUT_ROOT}/macos_network_${TIMESTAMP}}"
APP_PATH="${APP_PATH:-${PROJECT_ROOT}/build/macos/Build/Products/Debug/ZEON.app}"
EXTENSION_PATH="${EXTENSION_PATH:-${APP_PATH}/Contents/PlugIns/ZeonPacketTunnel.appex}"
APP_GROUP_ID="${APP_GROUP_ID:-}"
TEST_URL="${TEST_URL:-https://example.com}"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-12334}"
BUILD=1
BUILD_CORE=1
INTERACTIVE=1
OPEN_APP=1
CLEAN_CHECK=1
APP_LAUNCHED=0
WAIT_AFTER_ACTION="${WAIT_AFTER_ACTION:-8}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

usage() {
  cat <<'EOF'
Usage: scripts/apple/macos_network_diagnostics.sh [options]

One-command macOS VPN/proxy diagnostics for Zeon.

Options:
  --no-core-build     Do not build hiddify-core/bin/HiddifyCore.xcframework if missing.
  --no-build          Do not run flutter build macos --debug.
  --no-open           Do not launch the app automatically.
  --non-interactive   Do not pause for manual connect/disconnect.
  --skip-clean-check  Do not pause when Happ/other known VPN markers are detected.
  --app PATH          Use an existing .app bundle.
  --out DIR           Write diagnostics to DIR.
  --url URL           Test URL. Default: https://example.com
  --proxy-port PORT   Expected local mixed proxy port. Default: 12334
  -h, --help          Show this help.

Recommended clean run:
  1. Quit Happ and any other VPN/proxy client when the script asks.
  2. Run this script.
  3. When prompted, click Connect in Zeon and approve the macOS VPN popup.
  4. Wait until UI settles, then press Enter in this terminal.
  5. When prompted, click Disconnect in Zeon, wait until UI settles, press Enter.

Output:
  out/diagnostics/macos_network_YYYYMMDD_HHMMSS/SUMMARY.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-core-build)
      BUILD_CORE=0
      shift
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    --no-open)
      OPEN_APP=0
      shift
      ;;
    --non-interactive)
      INTERACTIVE=0
      shift
      ;;
    --skip-clean-check)
      CLEAN_CHECK=0
      shift
      ;;
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --url)
      TEST_URL="$2"
      shift 2
      ;;
    --proxy-port)
      PROXY_PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${APP_GROUP_ID}" ]]; then
  MACOS_BUNDLE_ID="$(
    awk -F= '/^MACOS_BUNDLE_IDENTIFIER[[:space:]]*=/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
    }' macos/Runner/Configs/AppInfo.xcconfig macos/Runner/Configs/AppleSigning.xcconfig 2>/dev/null | tail -1
  )"
  APP_GROUP_ID="group.${MACOS_BUNDLE_ID:-app.zeon.ios}"
fi

mkdir -p "${OUT_DIR}/logs" "${OUT_DIR}/snapshots"
SUMMARY="${OUT_DIR}/SUMMARY.md"
COMMAND_LOG="${OUT_DIR}/commands.log"

log_note() {
  printf '%s\n' "$*" | tee -a "${COMMAND_LOG}"
}

run_capture() {
  local name="$1"
  shift
  log_note "### ${name}"
  log_note "\$ $*"
  {
    echo "\$ $*"
    "$@"
  } >"${OUT_DIR}/logs/${name}.log" 2>&1 || {
    local code=$?
    echo "exit_code=${code}" >>"${OUT_DIR}/logs/${name}.log"
    log_note "exit_code=${code}"
    return 0
  }
}

run_shell() {
  local name="$1"
  local script="$2"
  log_note "### ${name}"
  log_note "\$ ${script}"
  {
    echo "\$ ${script}"
    bash -lc "${script}"
  } >"${OUT_DIR}/logs/${name}.log" 2>&1 || {
    local code=$?
    echo "exit_code=${code}" >>"${OUT_DIR}/logs/${name}.log"
    log_note "exit_code=${code}"
    return 0
  }
}

stop_zeon_processes() {
  log_note "### stop_zeon_processes"
  {
    echo "# stop_zeon_processes"
    date
    pkill -f 'ZeonPacketTunnel\.appex/Contents/MacOS/ZeonPacketTunnel' 2>/dev/null || true
    pkill -x ZEON 2>/dev/null || true
    sleep 2
    ps aux | filter_lines '[H]iddify|[P]acketTunnel' || true
  } >"${OUT_DIR}/logs/stop_zeon_processes.log" 2>&1
}

cleanup_stale_registered_apps() {
  local expected_bundle_id stale_count=0
  expected_bundle_id="$(
    awk -F= '/^MACOS_BUNDLE_IDENTIFIER[[:space:]]*=/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
    }' macos/Runner/Configs/AppInfo.xcconfig macos/Runner/Configs/AppleSigning.xcconfig 2>/dev/null | tail -1
  )"
  expected_bundle_id="${expected_bundle_id:-app.zeon.ios}"
  log_note "### cleanup_stale_registered_apps"
  {
    echo "# cleanup_stale_registered_apps"
    date
    echo "APP_PATH=${APP_PATH}"
    echo "EXTENSION_PATH=${EXTENSION_PATH}"
    echo "expected_bundle_id=${expected_bundle_id}"
    if [[ -d "${HOME}/Library/Developer/Xcode/DerivedData" ]]; then
      while IFS= read -r app; do
        [[ "${app}" == "${APP_PATH}" ]] && continue
        local bundle_id
        bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "${app}/Contents/Info.plist" 2>/dev/null || true)"
        [[ "${bundle_id}" == "${expected_bundle_id}" ]] || continue
        stale_count=$((stale_count + 1))
        echo "Removing stale registered app: ${app}"
        "${LSREGISTER}" -u "${app}" 2>/dev/null || true
        if [[ -d "${app}/Contents/PlugIns/ZeonPacketTunnel.appex" ]]; then
          pluginkit -r "${app}/Contents/PlugIns/ZeonPacketTunnel.appex" 2>/dev/null || true
        fi
        rm -rf "${app}"
      done < <(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/*/ZEON.app' -type d -print 2>/dev/null)
    fi
    echo "stale_removed=${stale_count}"
  } >"${OUT_DIR}/logs/cleanup_stale_registered_apps.log" 2>&1
}

register_current_app_bundle() {
  [[ -d "${APP_PATH}" ]] || return 0
  local registered_bundle_id
  registered_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
  registered_bundle_id="${registered_bundle_id:-app.zeon.ios}"
  log_note "### register_current_app_bundle"
  {
    echo "# register_current_app_bundle"
    date
    echo "APP_PATH=${APP_PATH}"
    echo "EXTENSION_PATH=${EXTENSION_PATH}"
    echo "registered_bundle_id=${registered_bundle_id}"
    "${LSREGISTER}" -f -R -trusted "${APP_PATH}" 2>&1 || true
    if [[ -d "${EXTENSION_PATH}" ]]; then
      pluginkit -a "${EXTENSION_PATH}" 2>&1 || true
    fi
    echo "REGISTERED_PLUGINS"
    pluginkit -m -A -D -vvv -i "${registered_bundle_id}.ZeonPacketTunnel" 2>&1 || true
  } >"${OUT_DIR}/logs/register_current_app_bundle.log" 2>&1
}

happ_detected() {
  local commands
  commands="$(ps ax -o command= 2>/dev/null || true)"
  [[ "${commands}" == *"Happ.app/Contents/MacOS/Happ"* ||
    "${commands}" == *"Happ.app/Contents/MacOS/core/xray"* ||
    "${commands}" == *"Happ.app/Contents/MacOS/tun/sing-box"* ||
    "${commands}" == *"/tun/sing-box"* ]]
}

known_vpn_markers() {
  ps aux | filter_lines '[H]app|[M]ullvad|[C]lash|[S]urge|[S]hadowrocket|[S]ing-box|[s]ing-box|[X]ray|[x]ray|[P]acketTunnel|[N]etworkExtension'
}

wait_for_clean_network() {
  if [[ "${CLEAN_CHECK}" -ne 1 ]]; then
    return 0
  fi

  if ! happ_detected; then
    return 0
  fi

  {
    echo "# Known VPN markers before clean wait"
    date
    known_vpn_markers || true
  } >"${OUT_DIR}/logs/clean_network_blocker.log" 2>&1

  if [[ "${INTERACTIVE}" -ne 1 ]]; then
    log_note "Clean network blocker detected; continuing because --non-interactive is set."
    return 0
  fi

  echo
  echo "Clean check: Happ/other VPN marker is running. Quit Happ and any other VPN client, then press Enter."
  echo "The current marker list is saved to logs/clean_network_blocker.log."
  read -r _

  while happ_detected; do
    echo "Still detected. Quit it fully, then press Enter again."
    known_vpn_markers || true
    read -r _
  done
}

filter_lines() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -i "${pattern}" || true
  else
    grep -Ei "${pattern}" || true
  fi
}

filter_lines_with_numbers() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -n "${pattern}" || true
  else
    grep -En "${pattern}" || true
  fi
}

active_service() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' | while read -r iface; do
    networksetup -listallhardwareports 2>/dev/null |
      awk -v iface="${iface}" '
        /^Hardware Port: / { port=substr($0, 16) }
        /^Device: / && $2 == iface { print port; found=1; exit }
        END { if (!found && iface != "") print iface }
      '
  done
}

capture_snapshot() {
  local stage="$1"
  local file="${OUT_DIR}/snapshots/${stage}.txt"
  local service
  service="$(active_service || true)"
  {
    echo "# ${stage}"
    echo
    echo "## date"
    date
    echo
    echo "## active network service"
    echo "${service:-unknown}"
    echo
    echo "## processes"
    ps aux | filter_lines '[H]iddify|[h]iddify-core|[s]ing-box|[P]acketTunnel|[N]etworkExtension|[H]app'
    echo
    echo "## system extensions"
    systemextensionsctl list || true
    echo
    echo "## network services"
    scutil --nc list || true
    echo
    echo "## interfaces"
    ifconfig | filter_lines_with_numbers '^(utun|tun|tap|lo|en|bridge|anpi|ap|awdl|llw)[0-9]+:|inet '
    echo
    echo "## default route"
    route -n get default || true
    echo
    echo "## ipv4 routes"
    netstat -rn -f inet | head -120 || true
    echo
    echo "## dns"
    scutil --dns | sed -n '1,220p' || true
    echo
    echo "## network extension preferences"
    plutil -p /Library/Preferences/com.apple.networkextension.plist 2>/dev/null | sed -n '1,220p' || true
    echo
    echo "## listeners"
    lsof -nP -iTCP -sTCP:LISTEN | filter_lines "ZEON|hiddify-core|sing|core|:${PROXY_PORT}|:12334|:12336|:12337|:789|:2080|:1080|:8080|:9090|:9091"
    echo
    echo "## proxy settings"
    if [[ -n "${service:-}" ]]; then
      echo "### ${service}"
      networksetup -getwebproxy "${service}" 2>/dev/null || true
      networksetup -getsecurewebproxy "${service}" 2>/dev/null || true
      networksetup -getsocksfirewallproxy "${service}" 2>/dev/null || true
    fi
    echo
    echo "## direct url"
    curl -I --max-time 20 "${TEST_URL}" || true
    echo
    echo "## local proxy url"
    curl -I --max-time 20 --proxy "http://${PROXY_HOST}:${PROXY_PORT}" "${TEST_URL}" || true
  } >"${file}" 2>&1
}

copy_runtime_logs() {
  local stage="$1"
  local dest="${OUT_DIR}/runtime-${stage}"
  local support_id="${APP_GROUP_ID#group.}"
  local support="${HOME}/Library/Application Support/${support_id}"
  local group="${HOME}/Library/Group Containers/${APP_GROUP_ID}"
  mkdir -p "${dest}"
  [[ -f "${support}/app.log" ]] && cp "${support}/app.log" "${dest}/app.log"
  [[ -f "${support}/box.log" ]] && cp "${support}/box.log" "${dest}/box-root.log"
  [[ -f "${support}/data/box.log" ]] && cp "${support}/data/box.log" "${dest}/box-data.log"
  [[ -f "${support}/data/stderrGRPC_NORMAL_INSECURE.log" ]] && cp "${support}/data/stderrGRPC_NORMAL_INSECURE.log" "${dest}/stderrGRPC_NORMAL_INSECURE.log"
  [[ -f "${support}/data/current-config.json" ]] && cp "${support}/data/current-config.json" "${dest}/current-config.json"
  if [[ -d "${group}" ]]; then
    {
      echo "Group container: ${group}"
      find "${group}" -maxdepth 6 \( -name '*.log' -o -name 'current-config.json' -o -name 'packet-tunnel-config.json' -o -name 'network_extension_error.log' \) -print
    } >"${dest}/group-container-files.txt" 2>&1 || true
    while IFS= read -r file; do
      local rel safe
      rel="${file#"${group}/"}"
      safe="${rel//\//__}"
      cp "${file}" "${dest}/group-${safe}" 2>/dev/null || true
    done < <(find "${group}" -maxdepth 6 \( -name '*.log' -o -name 'current-config.json' -o -name 'packet-tunnel-config.json' -o -name 'network_extension_error.log' \) -print 2>/dev/null)
  fi
}

write_summary() {
  local happ_status="not detected"
  local zeon_status="not detected"
  local proxy_status="not listening"
  local appex_status="missing"
  local ne_config_status="unknown"
  local runtime_provider_status="not detected"
  local service
  service="$(active_service || true)"

  if happ_detected; then
    happ_status="detected"
  fi
  local commands
  commands="$(ps ax -o command= 2>/dev/null || true)"
  if [[ "${commands}" == *"ZEON.app/Contents/MacOS/ZEON"* || "${commands}" == *"/ZEON" ]]; then
    zeon_status="running"
  fi
  if lsof -nP -iTCP:"${PROXY_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    proxy_status="listening"
  fi
  if [[ -d "${EXTENSION_PATH}" ]]; then
    appex_status="present"
  fi
  if scutil --nc list 2>/dev/null | grep -Eqi 'Zeon|app\.zeon|PacketTunnel'; then
    ne_config_status="detected"
  else
    ne_config_status="not detected"
  fi
  local runtime_provider_path
  runtime_provider_path="$(
    ps ax -o command= 2>/dev/null |
      awk '
        match($0, /\/.*ZeonPacketTunnel\.appex\/Contents\/MacOS\/ZeonPacketTunnel/) {
          print substr($0, RSTART, RLENGTH)
          exit
        }
      '
  )"
  if [[ -z "${runtime_provider_path}" && -f "${OUT_DIR}/snapshots/after_connect.txt" ]]; then
    runtime_provider_path="$(
      awk '
        match($0, /\/.*ZeonPacketTunnel\.appex\/Contents\/MacOS\/ZeonPacketTunnel/) {
          print substr($0, RSTART, RLENGTH)
          exit
        }
      ' "${OUT_DIR}/snapshots/after_connect.txt"
    )"
  fi
  if [[ -n "${runtime_provider_path}" ]]; then
    if [[ "${runtime_provider_path}" == "${EXTENSION_PATH}/Contents/MacOS/ZeonPacketTunnel" ]]; then
      runtime_provider_status="fresh (${runtime_provider_path})"
    else
      runtime_provider_status="stale-or-different (${runtime_provider_path})"
    fi
  fi

  cat >"${SUMMARY}" <<EOF
# macOS Network Diagnostics ${TIMESTAMP}

## Result Snapshot

- Output directory: \`${OUT_DIR}\`
- Active network service: \`${service:-unknown}\`
- Happ/other VPN marker: \`${happ_status}\`
- ZEON app process: \`${zeon_status}\`
- Packet Tunnel appex: \`${appex_status}\`
- Packet Tunnel runtime path: \`${runtime_provider_status}\`
- Network Configuration entry: \`${ne_config_status}\`
- Expected proxy listener \`${PROXY_HOST}:${PROXY_PORT}\`: \`${proxy_status}\`
- Test URL: \`${TEST_URL}\`

## Important Files

- Commands: \`commands.log\`
- Environment: \`logs/environment.log\`
- Build: \`logs/macos_signed_debug_build.log\`
- Host entitlements: \`logs/host_entitlements.log\`
- Packet Tunnel entitlements: \`logs/packet_tunnel_entitlements.log\`
- App bundle layout: \`logs/app_bundle_layout.log\`
- Console logs: \`logs/console_recent.log\`
- Snapshots: \`snapshots/pre_launch.txt\`, \`snapshots/after_launch.txt\`, \`snapshots/after_connect.txt\`, \`snapshots/after_disconnect.txt\`
- Runtime logs: \`runtime-*/\`

## How To Hand Off

Attach or paste this whole directory path:

\`\`\`
${OUT_DIR}
\`\`\`

The next agent can inspect \`SUMMARY.md\`, then compare snapshots and runtime logs without needing to reproduce the clean network state.
EOF
}

log_note "Writing diagnostics to ${OUT_DIR}"

wait_for_clean_network
stop_zeon_processes
cleanup_stale_registered_apps

run_shell environment 'sw_vers; echo XCODE; xcodebuild -version; echo XCODE_SELECT; xcode-select -p; echo FLUTTER; flutter --version; echo DART; dart --version; echo POD; pod --version; echo DEVICES; flutter devices'
run_shell project_inventory 'xcodebuild -list -project macos/Runner.xcodeproj; echo BUILD_SETTINGS; xcodebuild -showBuildSettings -project macos/Runner.xcodeproj -scheme Runner | grep -E "PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|CODE_SIGN_ENTITLEMENTS|BASE_BUNDLE_IDENTIFIER|SERVICE_IDENTIFIER" || true; echo DEBUG_ENTITLEMENTS; plutil -p macos/Runner/DebugProfile.entitlements; echo RELEASE_ENTITLEMENTS; plutil -p macos/Runner/Release.entitlements; echo PACKET_TUNNEL_ENTITLEMENTS; plutil -p macos/ZeonPacketTunnel/ZeonPacketTunnel.entitlements 2>/dev/null || true; echo PACKET_TUNNEL_INFO; plutil -p macos/ZeonPacketTunnel/Info.plist 2>/dev/null || true; echo MACOS_NE_REFS; if command -v rg >/dev/null 2>&1; then rg -n "NetworkExtension|SystemExtension|PacketTunnel|Provider|com.apple.developer.networking.networkextension|com.apple.security.application-groups|ZeonPacketTunnel" macos ios/Base.xcconfig macos/Runner.xcodeproj/project.pbxproj || true; else grep -REn "NetworkExtension|SystemExtension|PacketTunnel|Provider|com.apple.developer.networking.networkextension|com.apple.security.application-groups|ZeonPacketTunnel" macos ios/Base.xcconfig macos/Runner.xcodeproj/project.pbxproj || true; fi'

  if [[ "${BUILD_CORE}" -eq 1 && ! -d "${PROJECT_ROOT}/hiddify-core/bin/HiddifyCore.xcframework" ]]; then
  run_shell build_hiddify_core_xcframework 'cd hiddify-core && go run ./cmd/internal/build_libcore -target ios'
else
  run_shell hiddify_core_xcframework_inventory 'test -d hiddify-core/bin/HiddifyCore.xcframework && plutil -p hiddify-core/bin/HiddifyCore.xcframework/Info.plist || true'
fi

if [[ "${BUILD}" -eq 1 ]]; then
  rm -rf "${APP_PATH}"
  run_shell macos_signed_debug_build 'flutter pub get && (cd macos && pod install) && xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination "platform=macOS" -derivedDataPath build/macos -allowProvisioningUpdates -allowProvisioningDeviceRegistration build'
fi

register_current_app_bundle

if [[ -d "${APP_PATH}" ]]; then
  run_shell app_bundle_layout "find '${APP_PATH}' -maxdepth 6 \\( -name '*.appex' -o -name 'HiddifyCore*' -o -name 'hiddify-core*' \\) -print; echo APP_INFO; plutil -p '${APP_PATH}/Contents/Info.plist' | grep -E 'CFBundleIdentifier|BASE_BUNDLE_IDENTIFIER|SERVICE_IDENTIFIER' || true; echo EXTENSION_INFO; plutil -p '${EXTENSION_PATH}/Contents/Info.plist' 2>/dev/null | grep -E 'CFBundleIdentifier|NSExtension|BASE_BUNDLE_IDENTIFIER|Principal' || true; echo EXTENSION_CODE_MARKERS; strings '${EXTENSION_PATH}/Contents/MacOS/ZeonPacketTunnel.debug.dylib' 2>/dev/null | grep -E 'packet-tunnel-config|prepared config|default_interface|auto_detect_interface|PrimaryInterface|platform interfaces|no physical default' || true"
  run_shell host_entitlements "codesign -d --entitlements :- '${APP_PATH}' 2>/dev/null || true; echo VERIFY; codesign --verify --deep --strict --verbose=2 '${APP_PATH}' || true"
  if [[ -d "${EXTENSION_PATH}" ]]; then
    run_shell packet_tunnel_entitlements "codesign -d --entitlements :- '${EXTENSION_PATH}' 2>/dev/null || true; echo VERIFY_EXTENSION; codesign --verify --strict --verbose=2 '${EXTENSION_PATH}' || true"
  else
    log_note "Packet Tunnel extension not found: ${EXTENSION_PATH}"
  fi
else
  log_note "App bundle not found: ${APP_PATH}"
fi

capture_snapshot pre_launch
copy_runtime_logs pre_launch

if [[ "${OPEN_APP}" -eq 1 && -d "${APP_PATH}" ]]; then
  log_note "### open_app"
  log_note "$ open ${APP_PATH}"
  if open "${APP_PATH}" >"${OUT_DIR}/logs/open_app.log" 2>&1; then
    APP_LAUNCHED=1
  else
    code=$?
    echo "exit_code=${code}" >>"${OUT_DIR}/logs/open_app.log"
    log_note "exit_code=${code}"
  fi
  sleep "${WAIT_AFTER_ACTION}"
fi

capture_snapshot after_launch
copy_runtime_logs after_launch

if [[ "${OPEN_APP}" -eq 1 && "${APP_LAUNCHED}" -ne 1 ]]; then
  run_shell crash_reports "find '${HOME}/Library/Logs/DiagnosticReports' -maxdepth 1 -type f \\( -name 'ZEON*.crash' -o -name 'ZEON*.ips' -o -name 'ZeonPacketTunnel*.crash' -o -name 'ZeonPacketTunnel*.ips' \\) -print0 2>/dev/null | xargs -0 ls -lt 2>/dev/null | head -20; latest=\$(find '${HOME}/Library/Logs/DiagnosticReports' -maxdepth 1 -type f \\( -name 'ZEON*.crash' -o -name 'ZEON*.ips' \\) -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1); if [[ -n \"\${latest:-}\" ]]; then echo LATEST_CRASH=\"\${latest}\"; sed -n '1,220p' \"\${latest}\"; fi"
  run_shell launch_failure_console "/usr/bin/log show --last 10m --style compact --predicate 'process CONTAINS[c] \"ZEON\" OR eventMessage CONTAINS[c] \"ZEON\" OR eventMessage CONTAINS[c] \"Code Signature\" OR eventMessage CONTAINS[c] \"restricted entitlements\" OR eventMessage CONTAINS[c] \"Taskgated\" OR eventMessage CONTAINS[c] \"No profiles\" OR eventMessage CONTAINS[c] \"No Accounts\"' | tail -500"
  write_summary
  echo
  echo "App did not launch; diagnostics stopped before manual Connect."
  echo "${SUMMARY}"
  exit 1
fi

if [[ "${INTERACTIVE}" -eq 1 ]]; then
  echo
  echo "Manual step: click Connect in Zeon, approve the macOS VPN popup if it appears, wait until the UI settles, then press Enter."
  read -r _
  sleep "${WAIT_AFTER_ACTION}"
  capture_snapshot after_connect
  copy_runtime_logs after_connect

  echo
  echo "Manual step: click Disconnect in Zeon, wait until the UI settles, then press Enter."
  read -r _
  sleep "${WAIT_AFTER_ACTION}"
  capture_snapshot after_disconnect
  copy_runtime_logs after_disconnect
else
  capture_snapshot after_connect
  copy_runtime_logs after_connect
  capture_snapshot after_disconnect
  copy_runtime_logs after_disconnect
fi

run_shell console_recent '/usr/bin/log show --last 30m --style compact --predicate '\''process CONTAINS[c] "ZEON" OR process CONTAINS[c] "hiddify" OR process CONTAINS[c] "PacketTunnel" OR eventMessage CONTAINS[c] "ZEON" OR eventMessage CONTAINS[c] "hiddify-core" OR eventMessage CONTAINS[c] "sing-box" OR eventMessage CONTAINS[c] "NetworkExtension" OR eventMessage CONTAINS[c] "PacketTunnel" OR eventMessage CONTAINS[c] "NETunnelProvider" OR eventMessage CONTAINS[c] "NEPacketTunnel"'\'' | tail -900'
run_shell packet_tunnel_recent '/usr/bin/log show --last 30m --style compact --predicate '\''process CONTAINS[c] "ZeonPacketTunnel" OR eventMessage CONTAINS[c] "ZeonPacketTunnel" OR eventMessage CONTAINS[c] "PacketTunnelProvider" OR eventMessage CONTAINS[c] "network_extension_error" OR eventMessage CONTAINS[c] "NEPacketTunnel" OR eventMessage CONTAINS[c] "NETunnelProvider"'\'' | tail -900'
run_shell app_group_inventory "echo APP_GROUP=${APP_GROUP_ID}; find '${HOME}/Library/Group Containers/${APP_GROUP_ID}' -maxdepth 8 -print 2>/dev/null | sed -n '1,300p' || true; echo ERROR_LOGS; find '${HOME}/Library/Group Containers/${APP_GROUP_ID}' -maxdepth 8 -name 'network_extension_error.log' -print -exec tail -200 {} \\; 2>/dev/null || true"

write_summary

echo
echo "Diagnostics complete:"
echo "${SUMMARY}"
