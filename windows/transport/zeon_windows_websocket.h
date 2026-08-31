#pragma once

#include <cstdint>

#ifdef ZEON_WINDOWS_TRANSPORT_EXPORTS
#define ZEON_WS_API extern "C" __declspec(dllexport)
#else
#define ZEON_WS_API extern "C" __declspec(dllimport)
#endif

struct ZeonWsEvent {
  std::uint32_t struct_size;
  std::uint32_t type;
  std::uint32_t operation;
  std::uint32_t failure_stage;
  std::uint32_t win32_code;
  std::uint32_t http_status;
  std::uint32_t close_code;
  std::uint32_t proxy_auth_stage;
  std::uint32_t payload_length;
  std::uint32_t reserved;
  std::uint64_t sequence;
};

ZEON_WS_API std::uint32_t zeon_ws_api_version();

ZEON_WS_API std::uint64_t zeon_ws_connect(
    const wchar_t* url,
    const wchar_t* headers,
    std::uint32_t timeout_ms,
    std::uint32_t receive_timeout_ms,
    std::uint32_t proxy_mode,
    const wchar_t* named_proxy);

ZEON_WS_API std::int32_t zeon_ws_next_event(
    std::uint64_t session_id,
    ZeonWsEvent* event,
    std::uint8_t* payload,
    std::uint32_t payload_capacity,
    std::uint32_t wait_timeout_ms);

ZEON_WS_API std::int32_t zeon_ws_send(
    std::uint64_t session_id,
    const std::uint8_t* payload,
    std::uint32_t payload_length,
    std::uint32_t message_type);

ZEON_WS_API std::int32_t zeon_ws_close(
    std::uint64_t session_id,
    std::uint16_t close_code,
    const std::uint8_t* reason,
    std::uint32_t reason_length,
    std::uint32_t shutdown_timeout_ms);

ZEON_WS_API void zeon_ws_cancel(std::uint64_t session_id);
ZEON_WS_API void zeon_ws_release(std::uint64_t session_id);

ZEON_WS_API std::uint32_t zeon_ws_preferred_proxy_auth_scheme(
    std::uint32_t supported_schemes);

ZEON_WS_API std::uint32_t zeon_ws_classify_failure_stage(
    std::uint32_t win32_code,
    std::uint32_t operation,
    std::uint32_t secure);
