import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

class WindowsSystemHttpRequest {
  const WindowsSystemHttpRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.timeout,
    this.body,
    this.proxyMode = WindowsProxyMode.automatic,
    this.namedProxy,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final Duration timeout;
  final Uint8List? body;
  final WindowsProxyMode proxyMode;
  final String? namedProxy;
}

enum WindowsProxyMode { automatic, named, direct }

class WindowsSystemHttpResponse {
  const WindowsSystemHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.finalUrl,
  });

  final int statusCode;
  final Map<String, List<String>> headers;
  final Uint8List body;
  final String finalUrl;
}

abstract interface class WindowsSystemHttpTransport {
  Future<WindowsSystemHttpResponse> send(WindowsSystemHttpRequest request, {Future<Object?>? cancellation});
}

WindowsSystemHttpTransport? createWindowsSystemHttpTransport() =>
    Platform.isWindows ? const WinHttpWindowsSystemTransport() : null;

/// Windows-native system networking based on WinHTTP automatic proxy mode.
///
/// WinHTTP owns PAC/WPAD, per-user/system proxy selection, integrated proxy
/// authentication and TLS verification against the Windows trust stores. No
/// certificate-error suppression flags are set.
class WinHttpWindowsSystemTransport implements WindowsSystemHttpTransport {
  const WinHttpWindowsSystemTransport();

  @override
  Future<WindowsSystemHttpResponse> send(WindowsSystemHttpRequest request, {Future<Object?>? cancellation}) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WinHTTP is available only on Windows');
    }

    final resultPort = ReceivePort();
    final errorPort = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn<_WinHttpWorkerInput>(
        _winHttpWorkerMain,
        _WinHttpWorkerInput(request, resultPort.sendPort),
        errorsAreFatal: true,
        onError: errorPort.sendPort,
        debugName: 'zeon-winhttp-request',
      );

      final futures = <Future<WindowsSystemHttpResponse>>[
        resultPort.first.then(_decodeWorkerResult),
        errorPort.first.then<WindowsSystemHttpResponse>((error) {
          throw StateError('WinHTTP worker terminated unexpectedly: $error');
        }),
        Future<WindowsSystemHttpResponse>.delayed(
          _overallWorkerTimeout(request.timeout),
          () => throw const WindowsSystemNetworkException(
            operation: 'overall_timeout',
            stage: WindowsNetworkFailureStage.unknown,
            win32Code: _errorWinHttpTimeout,
            hresult: 0x80072ee2,
          ),
        ),
      ];
      if (cancellation != null) {
        futures.add(
          cancellation.then<WindowsSystemHttpResponse>(
            (reason) => throw WindowsSystemRequestCancelledException(reason),
          ),
        );
      }
      return await Future.any(futures);
    } finally {
      // The UI isolate never waits for a synchronous FFI call to unwind.
      // Native per-phase timeouts remain active if the OS call cannot be
      // interrupted immediately by terminating this Dart worker isolate.
      worker?.kill(priority: Isolate.immediate);
      resultPort.close();
      errorPort.close();
    }
  }
}

class WindowsSystemRequestCancelledException implements Exception {
  const WindowsSystemRequestCancelledException(this.reason);

  final Object? reason;
}

Duration _overallWorkerTimeout(Duration phaseTimeout) {
  final milliseconds = phaseTimeout.inMilliseconds.clamp(1, 0x1fffffff);
  final grace = (milliseconds ~/ 10).clamp(250, 1500);
  return Duration(milliseconds: milliseconds + grace);
}

class _WinHttpWorkerInput {
  const _WinHttpWorkerInput(this.request, this.resultPort);

  final WindowsSystemHttpRequest request;
  final SendPort resultPort;
}

void _winHttpWorkerMain(_WinHttpWorkerInput input) {
  try {
    input.resultPort.send(<Object?>[true, _performWinHttpRequest(input.request), null]);
  } catch (error, stackTrace) {
    final transferableError = error is WindowsSystemNetworkException ? error : error.toString();
    input.resultPort.send(<Object?>[false, transferableError, stackTrace.toString()]);
  }
}

WindowsSystemHttpResponse _decodeWorkerResult(Object? message) {
  if (message is! List<Object?> || message.length != 3) {
    throw StateError('WinHTTP worker returned an invalid result envelope');
  }
  if (message[0] == true && message[1] is WindowsSystemHttpResponse) {
    return message[1]! as WindowsSystemHttpResponse;
  }
  final error = message[1];
  if (error is WindowsSystemNetworkException) throw error;
  throw StateError('WinHTTP worker failed: $error');
}

enum WindowsNetworkFailureStage { dns, connect, tls, proxy, http, websocket, unknown }

class WindowsSystemNetworkException implements Exception {
  const WindowsSystemNetworkException({
    required this.operation,
    required this.stage,
    required this.win32Code,
    required this.hresult,
  });

  final String operation;
  final WindowsNetworkFailureStage stage;
  final int win32Code;
  final int hresult;

  @override
  String toString() =>
      'WindowsSystemNetworkException(operation=$operation, stage=${stage.name}, '
      'win32=$win32Code, hresult=0x${hresult.toUnsigned(32).toRadixString(16).padLeft(8, '0')})';
}

WindowsSystemHttpResponse _performWinHttpRequest(WindowsSystemHttpRequest request) {
  final uri = Uri.parse(request.url);
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError.value(uri.scheme, 'url', 'WinHTTP supports only HTTP(S)');
  }

  final api = _WinHttpApi();
  final handles = <int>[];
  Pointer<Utf16>? userAgent;
  Pointer<Utf16>? host;
  Pointer<Utf16>? verb;
  Pointer<Utf16>? target;
  Pointer<Utf16>? rawHeaders;
  Pointer<Uint8>? body;
  Pointer<Utf16>? namedProxy;

  Never fail(String operation) {
    final code = api.getLastError();
    throw WindowsSystemNetworkException(
      operation: operation,
      stage: _stageForWinHttpError(code, operation, secureRequest: uri.scheme == 'https'),
      win32Code: code,
      hresult: _hresultFromWin32(code),
    );
  }

  try {
    userAgent = (request.headers['User-Agent'] ?? request.headers['user-agent'] ?? 'ZEON').toNativeUtf16();
    if (request.proxyMode == WindowsProxyMode.named) {
      final value = request.namedProxy?.trim() ?? '';
      if (value.isEmpty) {
        throw ArgumentError.value(request.namedProxy, 'namedProxy', 'A named proxy endpoint is required');
      }
      namedProxy = value.toNativeUtf16();
    }
    final accessType = _accessTypeForProxyMode(request.proxyMode);
    final session = api.winHttpOpen(userAgent, accessType, namedProxy ?? nullptr, nullptr, 0);
    if (session == 0) fail('proxy_session');
    handles.add(session);

    final timeoutMs = request.timeout.inMilliseconds.clamp(1, 0x7fffffff);
    if (api.winHttpSetTimeouts(session, timeoutMs, timeoutMs, timeoutMs, timeoutMs) == 0) {
      fail('timeouts');
    }

    host = uri.host.toNativeUtf16();
    final connect = api.winHttpConnect(session, host, uri.port, 0);
    if (connect == 0) fail('connect');
    handles.add(connect);

    verb = request.method.toUpperCase().toNativeUtf16();
    final pathAndQuery = uri.hasQuery
        ? '${uri.path.isEmpty ? '/' : uri.path}?${uri.query}'
        : (uri.path.isEmpty ? '/' : uri.path);
    target = pathAndQuery.toNativeUtf16();
    final flags = uri.scheme == 'https' ? _winHttpFlagSecure : 0;
    final requestHandle = api.winHttpOpenRequest(connect, verb, target, nullptr, nullptr, nullptr, flags);
    if (requestHandle == 0) fail('open_request');
    handles.add(requestHandle);

    final sanitizedHeaders = <String, String>{...request.headers}
      ..removeWhere((key, _) => const {'host', 'content-length', 'connection'}.contains(key.toLowerCase()));
    final headerText = sanitizedHeaders.entries.map((entry) => '${entry.key}: ${entry.value}').join('\r\n');
    rawHeaders = headerText.isEmpty ? null : headerText.toNativeUtf16();
    final payload = request.body;
    if (payload != null && payload.isNotEmpty) {
      body = calloc<Uint8>(payload.length);
      body.asTypedList(payload.length).setAll(0, payload);
    }

    var attemptedIntegratedProxyAuth = false;
    late int statusCode;
    while (true) {
      if (api.winHttpSendRequest(
            requestHandle,
            rawHeaders ?? nullptr,
            rawHeaders == null ? 0 : 0xffffffff,
            body?.cast<Void>() ?? nullptr,
            payload?.length ?? 0,
            payload?.length ?? 0,
            0,
          ) ==
          0) {
        fail('send');
      }
      if (api.winHttpReceiveResponse(requestHandle, nullptr) == 0) fail('receive');

      statusCode = _queryStatusCode(api, requestHandle, fail);
      if (!shouldRetryIntegratedProxyAuthForTesting(statusCode, attemptedIntegratedProxyAuth)) break;
      attemptedIntegratedProxyAuth = true;
      _discardResponseBody(api, requestHandle, fail);
      if (!_applyDefaultIntegratedProxyCredentials(api, requestHandle)) break;
    }

    final responseHeaders = _queryResponseHeaders(api, requestHandle, fail);
    final responseBody = _readResponseBody(api, requestHandle, fail);
    final finalUrl = _queryFinalUrl(api, requestHandle) ?? request.url;
    return WindowsSystemHttpResponse(
      statusCode: statusCode,
      headers: responseHeaders,
      body: responseBody,
      finalUrl: finalUrl,
    );
  } finally {
    for (final handle in handles.reversed) {
      api.winHttpCloseHandle(handle);
    }
    if (userAgent != null) calloc.free(userAgent);
    if (host != null) calloc.free(host);
    if (verb != null) calloc.free(verb);
    if (target != null) calloc.free(target);
    if (rawHeaders != null) calloc.free(rawHeaders);
    if (body != null) calloc.free(body);
    if (namedProxy != null) calloc.free(namedProxy);
  }
}

int _accessTypeForProxyMode(WindowsProxyMode mode) => switch (mode) {
  WindowsProxyMode.automatic => _winHttpAccessTypeAutomaticProxy,
  WindowsProxyMode.named => _winHttpAccessTypeNamedProxy,
  WindowsProxyMode.direct => _winHttpAccessTypeNoProxy,
};

@visibleForTesting
int winHttpAccessTypeForTesting(WindowsProxyMode mode) => _accessTypeForProxyMode(mode);

bool _applyDefaultIntegratedProxyCredentials(_WinHttpApi api, int requestHandle) {
  final supportedSchemes = calloc<Uint32>();
  final firstScheme = calloc<Uint32>();
  final authTarget = calloc<Uint32>();
  try {
    if (api.winHttpQueryAuthSchemes(requestHandle, supportedSchemes, firstScheme, authTarget) == 0 ||
        authTarget.value != _winHttpAuthTargetProxy) {
      return false;
    }
    final scheme = _preferredIntegratedAuthScheme(supportedSchemes.value);
    if (scheme == 0) return false;
    return api.winHttpSetCredentials(requestHandle, _winHttpAuthTargetProxy, scheme, nullptr, nullptr, nullptr) != 0;
  } finally {
    calloc.free(supportedSchemes);
    calloc.free(firstScheme);
    calloc.free(authTarget);
  }
}

int _preferredIntegratedAuthScheme(int supportedSchemes) {
  if ((supportedSchemes & _winHttpAuthSchemeNegotiate) != 0) {
    return _winHttpAuthSchemeNegotiate;
  }
  if ((supportedSchemes & _winHttpAuthSchemeNtlm) != 0) {
    return _winHttpAuthSchemeNtlm;
  }
  return 0;
}

@visibleForTesting
int preferredIntegratedAuthSchemeForTesting(int supportedSchemes) => _preferredIntegratedAuthScheme(supportedSchemes);

@visibleForTesting
bool shouldRetryIntegratedProxyAuthForTesting(int statusCode, bool alreadyAttempted) =>
    statusCode == 407 && !alreadyAttempted;

int _queryStatusCode(_WinHttpApi api, int requestHandle, Never Function(String) fail) {
  final status = calloc<Uint32>();
  final size = calloc<Uint32>()..value = sizeOf<Uint32>();
  try {
    if (api.winHttpQueryHeaders(
          requestHandle,
          _winHttpQueryStatusCode | _winHttpQueryFlagNumber,
          nullptr,
          status.cast<Void>(),
          size,
          nullptr,
        ) ==
        0) {
      fail('http_status');
    }
    return status.value;
  } finally {
    calloc.free(status);
    calloc.free(size);
  }
}

Map<String, List<String>> _queryResponseHeaders(_WinHttpApi api, int requestHandle, Never Function(String) fail) {
  final size = calloc<Uint32>();
  try {
    api.winHttpQueryHeaders(requestHandle, _winHttpQueryRawHeadersCrlf, nullptr, nullptr, size, nullptr);
    if (size.value == 0) return const {};
    final buffer = calloc<Uint8>(size.value).cast<Utf16>();
    try {
      if (api.winHttpQueryHeaders(
            requestHandle,
            _winHttpQueryRawHeadersCrlf,
            nullptr,
            buffer.cast<Void>(),
            size,
            nullptr,
          ) ==
          0) {
        fail('response_headers');
      }
      final result = <String, List<String>>{};
      for (final line in buffer.toDartString().split(RegExp(r'\r?\n')).skip(1)) {
        final separator = line.indexOf(':');
        if (separator <= 0) continue;
        final name = line.substring(0, separator).trim().toLowerCase();
        final value = line.substring(separator + 1).trim();
        result.putIfAbsent(name, () => <String>[]).add(value);
      }
      return result;
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(size);
  }
}

Uint8List _readResponseBody(_WinHttpApi api, int requestHandle, Never Function(String) fail) {
  const chunkSize = 32 * 1024;
  const maxResponseBytes = 64 * 1024 * 1024;
  final chunk = calloc<Uint8>(chunkSize);
  final read = calloc<Uint32>();
  final builder = BytesBuilder(copy: false);
  try {
    while (true) {
      if (api.winHttpReadData(requestHandle, chunk.cast<Void>(), chunkSize, read) == 0) fail('read');
      if (read.value == 0) break;
      builder.add(Uint8List.fromList(chunk.asTypedList(read.value)));
      if (builder.length > maxResponseBytes) {
        throw const WindowsSystemNetworkException(
          operation: 'read_limit',
          stage: WindowsNetworkFailureStage.http,
          win32Code: 0,
          hresult: 0,
        );
      }
    }
    return builder.takeBytes();
  } finally {
    calloc.free(chunk);
    calloc.free(read);
  }
}

void _discardResponseBody(_WinHttpApi api, int requestHandle, Never Function(String) fail) {
  _readResponseBody(api, requestHandle, fail);
}

String? _queryFinalUrl(_WinHttpApi api, int requestHandle) {
  final size = calloc<Uint32>();
  try {
    api.winHttpQueryOption(requestHandle, _winHttpOptionUrl, nullptr, size);
    if (size.value == 0) return null;
    final buffer = calloc<Uint8>(size.value).cast<Utf16>();
    try {
      if (api.winHttpQueryOption(requestHandle, _winHttpOptionUrl, buffer.cast<Void>(), size) == 0) return null;
      return buffer.toDartString();
    } finally {
      calloc.free(buffer);
    }
  } finally {
    calloc.free(size);
  }
}

WindowsNetworkFailureStage _stageForWinHttpError(int code, String operation, {bool secureRequest = false}) {
  if (code == 12007) return WindowsNetworkFailureStage.dns;
  if (code == _errorWinHttpTimeout) {
    if (operation.contains('proxy')) return WindowsNetworkFailureStage.proxy;
    if (operation == 'receive' || operation == 'read') return WindowsNetworkFailureStage.http;
    return WindowsNetworkFailureStage.connect;
  }
  if (const {12029, 12030, 12031}.contains(code)) return WindowsNetworkFailureStage.connect;
  if (const {12037, 12038, 12044, 12045, 12157, 12169, 12170, 12175}.contains(code)) {
    return WindowsNetworkFailureStage.tls;
  }
  // A local TLS peer can abort the handshake before WinHTTP exposes a more
  // specific last-error code. Preserve the known protocol stage without
  // inventing a Win32 value; win32Code/hresult remain exactly zero.
  if (code == 0 && secureRequest && (operation == 'send' || operation == 'receive')) {
    return WindowsNetworkFailureStage.tls;
  }
  if (const {12009, 12015, 12166, 12167, 12178, 12180}.contains(code) || operation.contains('proxy')) {
    return WindowsNetworkFailureStage.proxy;
  }
  if (operation.contains('status') || operation.contains('header') || operation == 'read') {
    return WindowsNetworkFailureStage.http;
  }
  return WindowsNetworkFailureStage.unknown;
}

@visibleForTesting
WindowsNetworkFailureStage classifyWinHttpFailureStageForTesting(int code, String operation) =>
    _stageForWinHttpError(code, operation);

int _hresultFromWin32(int code) => code <= 0 ? code : (code & 0xffff) | 0x80070000;

const _winHttpAccessTypeAutomaticProxy = 4;
const _winHttpAccessTypeNamedProxy = 3;
const _winHttpAccessTypeNoProxy = 1;
const _winHttpFlagSecure = 0x00800000;
const _winHttpQueryStatusCode = 19;
const _winHttpQueryRawHeadersCrlf = 22;
const _winHttpQueryFlagNumber = 0x20000000;
const _winHttpOptionUrl = 34;
const _winHttpAuthTargetProxy = 1;
const _winHttpAuthSchemeNtlm = 0x00000002;
const _winHttpAuthSchemeNegotiate = 0x00000010;
const _errorWinHttpTimeout = 12002;

class _WinHttpApi {
  _WinHttpApi() {
    final winhttp = DynamicLibrary.open('winhttp.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    winHttpOpen = winhttp.lookupFunction<_WinHttpOpenNative, _WinHttpOpenDart>('WinHttpOpen');
    winHttpConnect = winhttp.lookupFunction<_WinHttpConnectNative, _WinHttpConnectDart>('WinHttpConnect');
    winHttpOpenRequest = winhttp.lookupFunction<_WinHttpOpenRequestNative, _WinHttpOpenRequestDart>(
      'WinHttpOpenRequest',
    );
    winHttpSetTimeouts = winhttp.lookupFunction<_WinHttpSetTimeoutsNative, _WinHttpSetTimeoutsDart>(
      'WinHttpSetTimeouts',
    );
    winHttpSendRequest = winhttp.lookupFunction<_WinHttpSendRequestNative, _WinHttpSendRequestDart>(
      'WinHttpSendRequest',
    );
    winHttpReceiveResponse = winhttp.lookupFunction<_WinHttpReceiveResponseNative, _WinHttpReceiveResponseDart>(
      'WinHttpReceiveResponse',
    );
    winHttpQueryHeaders = winhttp.lookupFunction<_WinHttpQueryHeadersNative, _WinHttpQueryHeadersDart>(
      'WinHttpQueryHeaders',
    );
    winHttpReadData = winhttp.lookupFunction<_WinHttpReadDataNative, _WinHttpReadDataDart>('WinHttpReadData');
    winHttpQueryOption = winhttp.lookupFunction<_WinHttpQueryOptionNative, _WinHttpQueryOptionDart>(
      'WinHttpQueryOption',
    );
    winHttpQueryAuthSchemes = winhttp.lookupFunction<_WinHttpQueryAuthSchemesNative, _WinHttpQueryAuthSchemesDart>(
      'WinHttpQueryAuthSchemes',
    );
    winHttpSetCredentials = winhttp.lookupFunction<_WinHttpSetCredentialsNative, _WinHttpSetCredentialsDart>(
      'WinHttpSetCredentials',
    );
    winHttpCloseHandle = winhttp.lookupFunction<_WinHttpCloseHandleNative, _WinHttpCloseHandleDart>(
      'WinHttpCloseHandle',
    );
    getLastError = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  }

  late final _WinHttpOpenDart winHttpOpen;
  late final _WinHttpConnectDart winHttpConnect;
  late final _WinHttpOpenRequestDart winHttpOpenRequest;
  late final _WinHttpSetTimeoutsDart winHttpSetTimeouts;
  late final _WinHttpSendRequestDart winHttpSendRequest;
  late final _WinHttpReceiveResponseDart winHttpReceiveResponse;
  late final _WinHttpQueryHeadersDart winHttpQueryHeaders;
  late final _WinHttpReadDataDart winHttpReadData;
  late final _WinHttpQueryOptionDart winHttpQueryOption;
  late final _WinHttpQueryAuthSchemesDart winHttpQueryAuthSchemes;
  late final _WinHttpSetCredentialsDart winHttpSetCredentials;
  late final _WinHttpCloseHandleDart winHttpCloseHandle;
  late final int Function() getLastError;
}

typedef _WinHttpOpenNative = IntPtr Function(Pointer<Utf16>, Uint32, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _WinHttpOpenDart = int Function(Pointer<Utf16>, int, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _WinHttpConnectNative = IntPtr Function(IntPtr, Pointer<Utf16>, Uint16, Uint32);
typedef _WinHttpConnectDart = int Function(int, Pointer<Utf16>, int, int);
typedef _WinHttpOpenRequestNative =
    IntPtr Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Pointer<Utf16>>,
      Uint32,
    );
typedef _WinHttpOpenRequestDart =
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Pointer<Utf16>>, int);
typedef _WinHttpSetTimeoutsNative = Int32 Function(IntPtr, Int32, Int32, Int32, Int32);
typedef _WinHttpSetTimeoutsDart = int Function(int, int, int, int, int);
typedef _WinHttpSendRequestNative =
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _WinHttpSendRequestDart = int Function(int, Pointer<Utf16>, int, Pointer<Void>, int, int, int);
typedef _WinHttpReceiveResponseNative = Int32 Function(IntPtr, Pointer<Void>);
typedef _WinHttpReceiveResponseDart = int Function(int, Pointer<Void>);
typedef _WinHttpQueryHeadersNative =
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _WinHttpQueryHeadersDart =
    int Function(int, int, Pointer<Utf16>, Pointer<Void>, Pointer<Uint32>, Pointer<Uint32>);
typedef _WinHttpReadDataNative = Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _WinHttpReadDataDart = int Function(int, Pointer<Void>, int, Pointer<Uint32>);
typedef _WinHttpQueryOptionNative = Int32 Function(IntPtr, Uint32, Pointer<Void>, Pointer<Uint32>);
typedef _WinHttpQueryOptionDart = int Function(int, int, Pointer<Void>, Pointer<Uint32>);
typedef _WinHttpQueryAuthSchemesNative = Int32 Function(IntPtr, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _WinHttpQueryAuthSchemesDart = int Function(int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _WinHttpSetCredentialsNative =
    Int32 Function(IntPtr, Uint32, Uint32, Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _WinHttpSetCredentialsDart = int Function(int, int, int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _WinHttpCloseHandleNative = Int32 Function(IntPtr);
typedef _WinHttpCloseHandleDart = int Function(int);
