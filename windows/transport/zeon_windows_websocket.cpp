#include "zeon_windows_websocket.h"

#include <windows.h>
#include <winhttp.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr std::uint32_t kApiVersion = 1;
constexpr std::size_t kReceiveChunkSize = 64 * 1024;
constexpr std::size_t kMaxMessageBytes = 8 * 1024 * 1024;
constexpr std::size_t kMaxQueuedEventBytes = 16 * 1024 * 1024;
constexpr std::size_t kMaxQueuedEvents = 128;
constexpr std::size_t kMaxQueuedSendBytes = 8 * 1024 * 1024;
constexpr std::size_t kMaxQueuedSends = 64;

enum EventType : std::uint32_t {
  kEventConnected = 1,
  kEventText = 2,
  kEventBinary = 3,
  kEventClose = 4,
  kEventError = 5,
};

enum Operation : std::uint32_t {
  kOperationNone = 0,
  kOperationOpen = 1,
  kOperationSendRequest = 2,
  kOperationReceiveResponse = 3,
  kOperationUpgrade = 4,
  kOperationReceive = 5,
  kOperationSend = 6,
  kOperationShutdown = 7,
  kOperationClose = 8,
  kOperationTimeout = 9,
  kOperationCancelled = 10,
  kOperationProxyAuth = 11,
};

enum FailureStage : std::uint32_t {
  kStageUnknown = 0,
  kStageDns = 1,
  kStageConnect = 2,
  kStageTls = 3,
  kStageProxy = 4,
  kStageHttp = 5,
  kStageWebSocket = 6,
};

enum ProxyAuthStage : std::uint32_t {
  kProxyAuthNone = 0,
  kProxyAuthRetrying = 1,
  kProxyAuthFailed = 2,
};

struct Event {
  ZeonWsEvent metadata{};
  std::vector<std::uint8_t> payload;
};

struct PendingSend {
  std::vector<std::uint8_t> payload;
  WINHTTP_WEB_SOCKET_BUFFER_TYPE type = WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
};

class Session;

std::mutex g_registry_mutex;
std::unordered_map<std::uint64_t, std::shared_ptr<Session>> g_sessions;
std::atomic<std::uint64_t> g_next_id{1};

std::shared_ptr<Session> FindSession(std::uint64_t id) {
  std::lock_guard<std::mutex> lock(g_registry_mutex);
  const auto iterator = g_sessions.find(id);
  return iterator == g_sessions.end() ? nullptr : iterator->second;
}

FailureStage ClassifyFailure(DWORD code, Operation operation, bool secure) {
  if (code == ERROR_WINHTTP_NAME_NOT_RESOLVED) return kStageDns;
  if (code == ERROR_WINHTTP_TIMEOUT) {
    if (operation == kOperationReceive) return kStageWebSocket;
    if (operation == kOperationProxyAuth) return kStageProxy;
    return kStageConnect;
  }
  if (code == ERROR_WINHTTP_CANNOT_CONNECT || code == ERROR_WINHTTP_CONNECTION_ERROR ||
      code == ERROR_WINHTTP_RESEND_REQUEST) {
    return kStageConnect;
  }
  if (code == ERROR_WINHTTP_AUTODETECTION_FAILED || code == ERROR_WINHTTP_BAD_AUTO_PROXY_SCRIPT ||
      code == ERROR_WINHTTP_UNABLE_TO_DOWNLOAD_SCRIPT || code == ERROR_WINHTTP_LOGIN_FAILURE ||
      operation == kOperationProxyAuth) {
    return kStageProxy;
  }
  if (code == ERROR_WINHTTP_SECURE_FAILURE || code == ERROR_WINHTTP_SECURE_CERT_DATE_INVALID ||
      code == ERROR_WINHTTP_SECURE_CERT_CN_INVALID || code == ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED ||
      code == ERROR_WINHTTP_SECURE_INVALID_CA || code == ERROR_WINHTTP_SECURE_CERT_REV_FAILED ||
      code == ERROR_WINHTTP_SECURE_CHANNEL_ERROR || code == ERROR_WINHTTP_SECURE_INVALID_CERT ||
      code == ERROR_WINHTTP_SECURE_CERT_REVOKED || code == ERROR_WINHTTP_SECURE_CERT_WRONG_USAGE ||
      code == ERROR_WINHTTP_SECURE_FAILURE_PROXY) {
    return kStageTls;
  }
  if (secure && code == ERROR_SUCCESS &&
      (operation == kOperationSendRequest || operation == kOperationReceiveResponse)) {
    return kStageTls;
  }
  if (code == ERROR_WINHTTP_OPERATION_CANCELLED) {
    return kStageWebSocket;
  }
  if (operation == kOperationSendRequest || operation == kOperationReceiveResponse) return kStageHttp;
  if (operation == kOperationReceive || operation == kOperationSend || operation == kOperationShutdown ||
      operation == kOperationClose) {
    return kStageWebSocket;
  }
  return kStageUnknown;
}

std::uint32_t PreferredProxyAuthScheme(std::uint32_t supported) {
  if ((supported & WINHTTP_AUTH_SCHEME_NEGOTIATE) != 0) return WINHTTP_AUTH_SCHEME_NEGOTIATE;
  if ((supported & WINHTTP_AUTH_SCHEME_NTLM) != 0) return WINHTTP_AUTH_SCHEME_NTLM;
  return 0;
}

class Session : public std::enable_shared_from_this<Session> {
 public:
  explicit Session(std::uint64_t id) : id_(id), receive_buffer_(kReceiveChunkSize) {}

  ~Session() {
    if (websocket_ != nullptr) WinHttpCloseHandle(websocket_);
    if (request_ != nullptr) WinHttpCloseHandle(request_);
    if (connect_ != nullptr) WinHttpCloseHandle(connect_);
    if (internet_ != nullptr) WinHttpCloseHandle(internet_);
  }

  bool Start(const wchar_t* raw_url,
             const wchar_t* headers,
             std::uint32_t timeout_ms,
             std::uint32_t receive_timeout_ms,
             std::uint32_t proxy_mode,
             const wchar_t* named_proxy) {
    timeout_ms_ = std::max<std::uint32_t>(1, timeout_ms);
    receive_timeout_ms_ = receive_timeout_ms;
    last_receive_activity_ = std::chrono::steady_clock::now();

    std::wstring url = raw_url == nullptr ? L"" : raw_url;
    if (url.rfind(L"wss://", 0) == 0) {
      secure_ = true;
      url.replace(0, 6, L"https://");
    } else if (url.rfind(L"ws://", 0) == 0) {
      url.replace(0, 5, L"http://");
    } else {
      Fail(kOperationOpen, ERROR_WINHTTP_INVALID_URL);
      return false;
    }

    URL_COMPONENTS components{};
    components.dwStructSize = sizeof(components);
    components.dwHostNameLength = static_cast<DWORD>(-1);
    components.dwUrlPathLength = static_cast<DWORD>(-1);
    components.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &components)) {
      Fail(kOperationOpen, GetLastError());
      return false;
    }
    std::wstring host(components.lpszHostName, components.dwHostNameLength);
    std::wstring path(components.lpszUrlPath, components.dwUrlPathLength);
    if (components.dwExtraInfoLength > 0) {
      path.append(components.lpszExtraInfo, components.dwExtraInfoLength);
    }
    if (path.empty()) path = L"/";

    DWORD access_type = WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY;
    LPCWSTR proxy_name = WINHTTP_NO_PROXY_NAME;
    if (proxy_mode == 1) {
      named_proxy_ = true;
      access_type = WINHTTP_ACCESS_TYPE_NAMED_PROXY;
      proxy_name = named_proxy;
    } else if (proxy_mode == 2) {
      access_type = WINHTTP_ACCESS_TYPE_NO_PROXY;
    }

    internet_ = WinHttpOpen(L"ZEON-Windows-WebSocket/1", access_type, proxy_name,
                            WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (internet_ == nullptr) {
      Fail(kOperationOpen, GetLastError());
      return false;
    }
    const int timeout = static_cast<int>(std::min<std::uint32_t>(timeout_ms_, INT_MAX));
    if (!WinHttpSetTimeouts(internet_, timeout, timeout, timeout, timeout)) {
      Fail(kOperationOpen, GetLastError());
      AbortHandles();
      return false;
    }
    const auto callback = WinHttpSetStatusCallback(
        internet_, &Session::StatusCallback,
        WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES |
            WINHTTP_CALLBACK_FLAG_SECURE_FAILURE,
        0);
    if (callback == WINHTTP_INVALID_STATUS_CALLBACK) {
      Fail(kOperationOpen, GetLastError());
      AbortHandles();
      return false;
    }

    connect_ = WinHttpConnect(internet_, host.c_str(), components.nPort, 0);
    if (connect_ == nullptr) {
      Fail(kOperationOpen, GetLastError());
      AbortHandles();
      return false;
    }
    request_ = WinHttpOpenRequest(connect_, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER,
                                  WINHTTP_DEFAULT_ACCEPT_TYPES,
                                  secure_ ? WINHTTP_FLAG_SECURE : 0);
    if (request_ == nullptr) {
      Fail(kOperationOpen, GetLastError());
      AbortHandles();
      return false;
    }
    DWORD_PTR context = reinterpret_cast<DWORD_PTR>(this);
    if (!WinHttpSetOption(request_, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context)) ||
        !WinHttpSetOption(request_, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
      Fail(kOperationUpgrade, GetLastError());
      AbortHandles();
      return false;
    }
    request_headers_ = headers == nullptr ? L"" : headers;
    open_callback_handles_.store(1);
    const BOOL sent = WinHttpSendRequest(
        request_, request_headers_.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : request_headers_.c_str(),
        request_headers_.empty() ? 0 : static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0, context);
    if (!sent && GetLastError() != ERROR_IO_PENDING) {
      Fail(kOperationSendRequest, GetLastError());
      AbortHandles();
      return false;
    }
    return true;
  }

  std::int32_t NextEvent(ZeonWsEvent* event,
                         std::uint8_t* payload,
                         std::uint32_t payload_capacity,
                         std::uint32_t wait_timeout_ms) {
    if (event == nullptr || event->struct_size != sizeof(ZeonWsEvent)) return -3;
    std::unique_lock<std::mutex> lock(mutex_);
    const auto wait_duration = std::chrono::milliseconds(wait_timeout_ms);
    condition_.wait_for(lock, wait_duration, [this] { return !events_.empty(); });
    CheckDeadlinesLocked(lock);
    if (events_.empty()) return 0;
    Event& next = events_.front();
    *event = next.metadata;
    if (next.payload.size() > payload_capacity) return -2;
    if (!next.payload.empty() && payload != nullptr) {
      std::memcpy(payload, next.payload.data(), next.payload.size());
    }
    queued_event_bytes_ -= next.payload.size();
    events_.pop_front();
    return 1;
  }

  std::int32_t QueueSend(const std::uint8_t* payload,
                         std::uint32_t payload_length,
                         std::uint32_t message_type) {
    if (payload_length > kMaxMessageBytes || (payload_length > 0 && payload == nullptr)) return -2;
    PendingSend send;
    if (payload_length > 0) send.payload.assign(payload, payload + payload_length);
    send.type = message_type == 1 ? WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE
                                  : WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
    bool start = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!connected_ || terminal_ || close_requested_) return -1;
      if (send_queue_.size() >= kMaxQueuedSends || queued_send_bytes_ + send.payload.size() > kMaxQueuedSendBytes) {
        return -3;
      }
      queued_send_bytes_ += send.payload.size();
      send_queue_.push_back(std::move(send));
      if (!write_outstanding_) {
        write_outstanding_ = true;
        start = true;
      }
    }
    if (start) StartCurrentSend();
    return 0;
  }

  std::int32_t RequestClose(std::uint16_t code,
                            const std::uint8_t* reason,
                            std::uint32_t reason_length,
                            std::uint32_t shutdown_timeout_ms) {
    if (reason_length > 123 || (reason_length > 0 && reason == nullptr)) return -2;
    bool start_shutdown = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_) return 0;
      close_requested_ = true;
      close_code_ = code == 0 ? WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS : code;
      close_reason_.assign(reason, reason + reason_length);
      close_deadline_ = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(std::max<std::uint32_t>(1, shutdown_timeout_ms));
      if (connected_ && !write_outstanding_ && !shutdown_outstanding_) {
        shutdown_outstanding_ = true;
        start_shutdown = true;
      }
    }
    if (start_shutdown) StartShutdown();
    condition_.notify_all();
    return 0;
  }

  void Cancel() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_) return;
      PushErrorLocked(kOperationCancelled, ERROR_WINHTTP_OPERATION_CANCELLED, kStageWebSocket, 0,
                      kProxyAuthNone);
      terminal_ = true;
    }
    condition_.notify_all();
    AbortHandles();
  }

  void Release() {
    release_requested_.store(true);
    MaybeErase();
  }

  static void CALLBACK StatusCallback(HINTERNET,
                                      DWORD_PTR context,
                                      DWORD status,
                                      LPVOID status_information,
                                      DWORD status_information_length) {
    if (context == 0) return;
    auto* raw = reinterpret_cast<Session*>(context);
    const auto session = FindSession(raw->id_);
    if (session == nullptr) return;
    session->OnStatus(status, status_information, status_information_length);
  }

 private:
  void OnStatus(DWORD status, LPVOID information, DWORD information_length) {
    switch (status) {
      case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
        OnSendRequestComplete();
        break;
      case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        OnHeadersAvailable();
        break;
      case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        OnReadComplete(information, information_length);
        break;
      case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        OnWriteComplete();
        break;
      case WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE:
        OnShutdownComplete();
        break;
      case WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE:
        OnCloseComplete();
        break;
      case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        OnRequestError(information, information_length);
        break;
      case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
        Fail(kOperationReceiveResponse, ERROR_WINHTTP_SECURE_FAILURE, kStageTls);
        AbortHandles();
        break;
      case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
        if (open_callback_handles_.fetch_sub(1) == 1) MaybeErase();
        break;
      default:
        break;
    }
  }

  void OnSendRequestComplete() {
    HINTERNET request = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_) return;
      request = request_;
    }
    if (request == nullptr || (!WinHttpReceiveResponse(request, nullptr) && GetLastError() != ERROR_IO_PENDING)) {
      Fail(kOperationReceiveResponse, GetLastError());
      AbortHandles();
    }
  }

  void OnHeadersAvailable() {
    HINTERNET request = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_) return;
      request = request_;
    }
    DWORD status_code = 0;
    DWORD status_size = sizeof(status_code);
    if (request == nullptr || !WinHttpQueryHeaders(request,
                                                   WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                                   WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size,
                                                   WINHTTP_NO_HEADER_INDEX)) {
      Fail(kOperationUpgrade, GetLastError());
      AbortHandles();
      return;
    }
    if (status_code == HTTP_STATUS_PROXY_AUTH_REQ) {
      if (TryProxyAuthRetry(request)) return;
      Fail(kOperationProxyAuth, ERROR_WINHTTP_LOGIN_FAILURE, kStageProxy, status_code,
           kProxyAuthFailed);
      AbortHandles();
      return;
    }
    if (status_code != HTTP_STATUS_SWITCH_PROTOCOLS) {
      Fail(kOperationUpgrade, ERROR_WINHTTP_INVALID_SERVER_RESPONSE,
           status_code >= 400 ? kStageHttp : kStageWebSocket, status_code);
      AbortHandles();
      return;
    }

    HINTERNET websocket = WinHttpWebSocketCompleteUpgrade(
        request, reinterpret_cast<DWORD_PTR>(this));
    if (websocket == nullptr) {
      Fail(kOperationUpgrade, GetLastError());
      AbortHandles();
      return;
    }
    open_callback_handles_.fetch_add(1);
    DWORD_PTR context = reinterpret_cast<DWORD_PTR>(this);
    if (!WinHttpSetOption(websocket, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context))) {
      const DWORD error = GetLastError();
      WinHttpCloseHandle(websocket);
      Fail(kOperationUpgrade, error);
      AbortHandles();
      return;
    }
    HINTERNET request_to_close = nullptr;
    bool cancelled_during_upgrade = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      request_to_close = request_;
      request_ = nullptr;
      cancelled_during_upgrade = terminal_;
      if (!cancelled_during_upgrade) {
        websocket_ = websocket;
        connected_ = true;
        last_receive_activity_ = std::chrono::steady_clock::now();
        PushEventLocked(kEventConnected, kOperationUpgrade, kStageUnknown, ERROR_SUCCESS,
                        status_code, 0, kProxyAuthNone, {});
      }
    }
    condition_.notify_all();
    if (request_to_close != nullptr) WinHttpCloseHandle(request_to_close);
    if (cancelled_during_upgrade) {
      WinHttpCloseHandle(websocket);
      return;
    }
    StartReceive();
  }

  bool TryProxyAuthRetry(HINTERNET request) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (proxy_auth_attempted_) return false;
      proxy_auth_attempted_ = true;
    }
    DWORD supported = 0;
    DWORD first = 0;
    DWORD target = 0;
    if (!WinHttpQueryAuthSchemes(request, &supported, &first, &target) ||
        target != WINHTTP_AUTH_TARGET_PROXY) {
      return false;
    }
    const DWORD scheme = PreferredProxyAuthScheme(supported);
    if (scheme == 0 || !WinHttpSetCredentials(request, WINHTTP_AUTH_TARGET_PROXY, scheme,
                                               nullptr, nullptr, nullptr)) {
      return false;
    }
    const BOOL sent = WinHttpSendRequest(
        request, request_headers_.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : request_headers_.c_str(),
        request_headers_.empty() ? 0 : static_cast<DWORD>(-1L), WINHTTP_NO_REQUEST_DATA, 0, 0,
        reinterpret_cast<DWORD_PTR>(this));
    if (!sent && GetLastError() != ERROR_IO_PENDING) return false;
    return true;
  }

  void StartReceive() {
    HINTERNET websocket = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_ || receive_outstanding_ || websocket_ == nullptr) return;
      receive_outstanding_ = true;
      websocket = websocket_;
    }
    const DWORD result = WinHttpWebSocketReceive(websocket, receive_buffer_.data(),
                                                 static_cast<DWORD>(receive_buffer_.size()), nullptr,
                                                 nullptr);
    if (result != ERROR_SUCCESS && result != ERROR_IO_PENDING) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        receive_outstanding_ = false;
      }
      Fail(kOperationReceive, result);
      AbortHandles();
    }
  }

  void OnReadComplete(LPVOID information, DWORD information_length) {
    if (information == nullptr || information_length < sizeof(WINHTTP_WEB_SOCKET_STATUS)) {
      Fail(kOperationReceive, ERROR_WINHTTP_INVALID_SERVER_RESPONSE);
      AbortHandles();
      return;
    }
    const auto* status = static_cast<WINHTTP_WEB_SOCKET_STATUS*>(information);
    bool receive_again = false;
    bool close_now = false;
    std::uint16_t remote_code = WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS;
    std::vector<std::uint8_t> remote_reason;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      receive_outstanding_ = false;
      if (terminal_) return;
      last_receive_activity_ = std::chrono::steady_clock::now();
      const auto type = status->eBufferType;
      if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
        DWORD reason_length = 0;
        WinHttpWebSocketQueryCloseStatus(websocket_, &remote_code, nullptr, 0, &reason_length);
        if (reason_length > 0 && reason_length <= 123) {
          remote_reason.resize(reason_length);
          WinHttpWebSocketQueryCloseStatus(websocket_, &remote_code, remote_reason.data(),
                                           reason_length, &reason_length);
          remote_reason.resize(reason_length);
        }
        PushEventLocked(kEventClose, kOperationClose, kStageUnknown, ERROR_SUCCESS, 101,
                        remote_code, kProxyAuthNone, std::move(remote_reason));
        terminal_ = true;
        close_now = true;
      } else {
        const bool binary = type == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE ||
                            type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
        const bool fragment = type == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE ||
                              type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE;
        if (fragment_buffer_.empty()) fragment_binary_ = binary;
        if (fragment_binary_ != binary ||
            fragment_buffer_.size() + status->dwBytesTransferred > kMaxMessageBytes) {
          PushErrorLocked(kOperationReceive, ERROR_INSUFFICIENT_BUFFER, kStageWebSocket, 0,
                          kProxyAuthNone);
          terminal_ = true;
          close_now = true;
        } else {
          fragment_buffer_.insert(fragment_buffer_.end(), receive_buffer_.begin(),
                                  receive_buffer_.begin() + status->dwBytesTransferred);
          if (!fragment) {
            PushEventLocked(binary ? kEventBinary : kEventText, kOperationReceive, kStageUnknown,
                            ERROR_SUCCESS, 101, 0, kProxyAuthNone, std::move(fragment_buffer_));
            fragment_buffer_.clear();
          }
          receive_again = true;
        }
      }
      if (terminal_) close_now = true;
    }
    condition_.notify_all();
    if (close_now) {
      StartProtocolClose(remote_code);
    } else if (receive_again) {
      StartReceive();
    }
  }

  void StartCurrentSend() {
    HINTERNET websocket = nullptr;
    const void* data = nullptr;
    DWORD length = 0;
    WINHTTP_WEB_SOCKET_BUFFER_TYPE type = WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (send_queue_.empty() || websocket_ == nullptr || terminal_) {
        write_outstanding_ = false;
        return;
      }
      websocket = websocket_;
      data = send_queue_.front().payload.empty() ? nullptr : send_queue_.front().payload.data();
      length = static_cast<DWORD>(send_queue_.front().payload.size());
      type = send_queue_.front().type;
    }
    const DWORD result = WinHttpWebSocketSend(websocket, type,
                                              const_cast<void*>(data), length);
    if (result != ERROR_SUCCESS && result != ERROR_IO_PENDING) {
      Fail(kOperationSend, result);
      AbortHandles();
    }
  }

  void OnWriteComplete() {
    bool start_next = false;
    bool start_shutdown = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!send_queue_.empty()) {
        queued_send_bytes_ -= send_queue_.front().payload.size();
        send_queue_.pop_front();
      }
      write_outstanding_ = false;
      if (terminal_) return;
      if (!send_queue_.empty()) {
        write_outstanding_ = true;
        start_next = true;
      } else if (close_requested_ && !shutdown_outstanding_) {
        shutdown_outstanding_ = true;
        start_shutdown = true;
      }
    }
    if (start_next) StartCurrentSend();
    if (start_shutdown) StartShutdown();
  }

  void StartShutdown() {
    HINTERNET websocket = nullptr;
    USHORT code = WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS;
    const void* reason = nullptr;
    DWORD reason_length = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (websocket_ == nullptr || terminal_) return;
      websocket = websocket_;
      code = close_code_;
      reason = close_reason_.empty() ? nullptr : close_reason_.data();
      reason_length = static_cast<DWORD>(close_reason_.size());
    }
    const DWORD result = WinHttpWebSocketShutdown(websocket, code,
                                                  const_cast<void*>(reason), reason_length);
    if (result != ERROR_SUCCESS && result != ERROR_IO_PENDING) {
      Fail(kOperationShutdown, result);
      AbortHandles();
    }
  }

  void OnShutdownComplete() {
    std::lock_guard<std::mutex> lock(mutex_);
    shutdown_outstanding_ = false;
  }

  void StartProtocolClose(std::uint16_t code) {
    HINTERNET websocket = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      websocket = websocket_;
    }
    if (websocket == nullptr) return;
    const DWORD result = WinHttpWebSocketClose(websocket, code, nullptr, 0);
    if (result != ERROR_SUCCESS && result != ERROR_IO_PENDING) {
      AbortHandles();
    }
  }

  void OnCloseComplete() { AbortHandles(); }

  void OnRequestError(LPVOID information, DWORD information_length) {
    DWORD error = ERROR_WINHTTP_INTERNAL_ERROR;
    Operation operation = kOperationSendRequest;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (shutdown_outstanding_) {
        operation = kOperationShutdown;
      } else if (write_outstanding_) {
        operation = kOperationSend;
      } else if (receive_outstanding_ || connected_) {
        operation = kOperationReceive;
      }
    }
    if (information != nullptr && information_length >= sizeof(WINHTTP_ASYNC_RESULT)) {
      const auto* result = static_cast<WINHTTP_ASYNC_RESULT*>(information);
      error = result->dwError;
      if (result->dwResult == API_RECEIVE_RESPONSE) operation = kOperationReceiveResponse;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (error == ERROR_WINHTTP_OPERATION_CANCELLED && terminal_) return;
    }
    Fail(operation, error);
    AbortHandles();
  }

  void Fail(Operation operation,
            DWORD error,
            std::optional<FailureStage> stage = std::nullopt,
            DWORD http_status = 0,
            ProxyAuthStage proxy_auth = kProxyAuthNone) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (terminal_) return;
      auto resolved_stage = stage.value_or(ClassifyFailure(error, operation, secure_));
      if (named_proxy_ && !connected_ && resolved_stage == kStageConnect) {
        resolved_stage = kStageProxy;
      }
      PushErrorLocked(operation, error, resolved_stage, http_status, proxy_auth);
      terminal_ = true;
    }
    condition_.notify_all();
  }

  void PushErrorLocked(Operation operation,
                       DWORD error,
                       FailureStage stage,
                       DWORD http_status,
                       ProxyAuthStage proxy_auth) {
    PushEventLocked(kEventError, operation, stage, error, http_status, close_code_, proxy_auth, {});
  }

  void PushEventLocked(EventType type,
                       Operation operation,
                       FailureStage stage,
                       DWORD error,
                       DWORD http_status,
                       DWORD close_code,
                       ProxyAuthStage proxy_auth,
                       std::vector<std::uint8_t>&& payload) {
    if (events_.size() >= kMaxQueuedEvents || queued_event_bytes_ + payload.size() > kMaxQueuedEventBytes) {
      if (type != kEventError) {
        events_.clear();
        queued_event_bytes_ = 0;
        Event overflow;
        overflow.metadata.struct_size = sizeof(ZeonWsEvent);
        overflow.metadata.type = kEventError;
        overflow.metadata.operation = kOperationReceive;
        overflow.metadata.failure_stage = kStageWebSocket;
        overflow.metadata.win32_code = ERROR_INSUFFICIENT_BUFFER;
        overflow.metadata.sequence = ++sequence_;
        events_.push_back(std::move(overflow));
        terminal_ = true;
      }
      return;
    }
    Event event;
    event.metadata.struct_size = sizeof(ZeonWsEvent);
    event.metadata.type = type;
    event.metadata.operation = operation;
    event.metadata.failure_stage = stage;
    event.metadata.win32_code = error;
    event.metadata.http_status = http_status;
    event.metadata.close_code = close_code;
    event.metadata.proxy_auth_stage = proxy_auth;
    event.metadata.payload_length = static_cast<std::uint32_t>(payload.size());
    event.metadata.sequence = ++sequence_;
    queued_event_bytes_ += payload.size();
    event.payload = std::move(payload);
    events_.push_back(std::move(event));
  }

  void CheckDeadlinesLocked(std::unique_lock<std::mutex>& lock) {
    const auto now = std::chrono::steady_clock::now();
    bool abort = false;
    if (!terminal_ && close_requested_ && close_deadline_.has_value() && now >= close_deadline_.value()) {
      PushErrorLocked(kOperationTimeout, ERROR_WINHTTP_TIMEOUT, kStageWebSocket, 0,
                      kProxyAuthNone);
      terminal_ = true;
      abort = true;
    } else if (!terminal_ && connected_ && receive_timeout_ms_ > 0 &&
               now - last_receive_activity_ >= std::chrono::milliseconds(receive_timeout_ms_)) {
      PushErrorLocked(kOperationReceive, ERROR_WINHTTP_TIMEOUT, kStageWebSocket, 0,
                      kProxyAuthNone);
      terminal_ = true;
      abort = true;
    }
    if (abort) {
      lock.unlock();
      condition_.notify_all();
      AbortHandles();
      lock.lock();
    }
  }

  void AbortHandles() {
    HINTERNET websocket = nullptr;
    HINTERNET request = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      websocket = websocket_;
      request = request_;
      websocket_ = nullptr;
      request_ = nullptr;
    }
    if (websocket != nullptr) WinHttpCloseHandle(websocket);
    if (request != nullptr) WinHttpCloseHandle(request);
    if (websocket == nullptr && request == nullptr) MaybeErase();
  }

  void MaybeErase() {
    if (!release_requested_.load() || open_callback_handles_.load() != 0) return;
    if (connect_ != nullptr) {
      WinHttpCloseHandle(connect_);
      connect_ = nullptr;
    }
    if (internet_ != nullptr) {
      WinHttpCloseHandle(internet_);
      internet_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    g_sessions.erase(id_);
  }

  const std::uint64_t id_;
  std::mutex mutex_;
  std::condition_variable condition_;
  HINTERNET internet_ = nullptr;
  HINTERNET connect_ = nullptr;
  HINTERNET request_ = nullptr;
  HINTERNET websocket_ = nullptr;
  std::wstring request_headers_;
  bool secure_ = false;
  bool named_proxy_ = false;
  bool connected_ = false;
  bool terminal_ = false;
  bool proxy_auth_attempted_ = false;
  bool receive_outstanding_ = false;
  bool write_outstanding_ = false;
  bool shutdown_outstanding_ = false;
  bool close_requested_ = false;
  std::uint16_t close_code_ = WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS;
  std::vector<std::uint8_t> close_reason_;
  std::optional<std::chrono::steady_clock::time_point> close_deadline_;
  std::chrono::steady_clock::time_point last_receive_activity_;
  std::uint32_t timeout_ms_ = 1;
  std::uint32_t receive_timeout_ms_ = 0;
  std::vector<std::uint8_t> receive_buffer_;
  std::vector<std::uint8_t> fragment_buffer_;
  bool fragment_binary_ = false;
  std::deque<PendingSend> send_queue_;
  std::size_t queued_send_bytes_ = 0;
  std::deque<Event> events_;
  std::size_t queued_event_bytes_ = 0;
  std::uint64_t sequence_ = 0;
  std::atomic<std::uint32_t> open_callback_handles_{0};
  std::atomic<bool> release_requested_{false};
};

}  // namespace

std::uint32_t zeon_ws_api_version() { return kApiVersion; }

std::uint64_t zeon_ws_connect(const wchar_t* url,
                              const wchar_t* headers,
                              std::uint32_t timeout_ms,
                              std::uint32_t receive_timeout_ms,
                              std::uint32_t proxy_mode,
                              const wchar_t* named_proxy) {
  if (url == nullptr || (proxy_mode == 1 && (named_proxy == nullptr || named_proxy[0] == L'\0'))) return 0;
  const std::uint64_t id = g_next_id.fetch_add(1);
  const auto session = std::make_shared<Session>(id);
  {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    g_sessions.emplace(id, session);
  }
  session->Start(url, headers, timeout_ms, receive_timeout_ms, proxy_mode, named_proxy);
  return id;
}

std::int32_t zeon_ws_next_event(std::uint64_t session_id,
                                ZeonWsEvent* event,
                                std::uint8_t* payload,
                                std::uint32_t payload_capacity,
                                std::uint32_t wait_timeout_ms) {
  const auto session = FindSession(session_id);
  return session == nullptr ? -1 : session->NextEvent(event, payload, payload_capacity, wait_timeout_ms);
}

std::int32_t zeon_ws_send(std::uint64_t session_id,
                          const std::uint8_t* payload,
                          std::uint32_t payload_length,
                          std::uint32_t message_type) {
  const auto session = FindSession(session_id);
  return session == nullptr ? -1 : session->QueueSend(payload, payload_length, message_type);
}

std::int32_t zeon_ws_close(std::uint64_t session_id,
                           std::uint16_t close_code,
                           const std::uint8_t* reason,
                           std::uint32_t reason_length,
                           std::uint32_t shutdown_timeout_ms) {
  const auto session = FindSession(session_id);
  return session == nullptr ? -1 : session->RequestClose(close_code, reason, reason_length, shutdown_timeout_ms);
}

void zeon_ws_cancel(std::uint64_t session_id) {
  const auto session = FindSession(session_id);
  if (session != nullptr) session->Cancel();
}

void zeon_ws_release(std::uint64_t session_id) {
  const auto session = FindSession(session_id);
  if (session != nullptr) session->Release();
}

std::uint32_t zeon_ws_preferred_proxy_auth_scheme(std::uint32_t supported_schemes) {
  return PreferredProxyAuthScheme(supported_schemes);
}

std::uint32_t zeon_ws_classify_failure_stage(std::uint32_t win32_code,
                                             std::uint32_t operation,
                                             std::uint32_t secure) {
  if (operation > kOperationProxyAuth) return kStageUnknown;
  return ClassifyFailure(win32_code, static_cast<Operation>(operation), secure != 0);
}
