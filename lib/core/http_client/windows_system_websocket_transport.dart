import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';

const _nativeApiVersion = 1;
const _maxMessageBytes = 8 * 1024 * 1024;
const _eventPollMilliseconds = 200;
const _defaultShutdownTimeout = Duration(seconds: 5);

WindowsSystemWebSocketTransport? createWindowsSystemWebSocketTransport() {
  if (!Platform.isWindows) return null;
  try {
    return WinHttpWindowsSystemWebSocketTransport(_resolveTransportLibrary());
  } catch (_) {
    return null;
  }
}

/// WinHTTP WebSocket transport backed by a minimal native asynchronous state
/// machine. WinHTTP callbacks own all blocking proxy/PAC, DNS, TLS and socket
/// work. A worker isolate only drains a bounded native event queue.
class WinHttpWindowsSystemWebSocketTransport implements WindowsSystemWebSocketTransport {
  WinHttpWindowsSystemWebSocketTransport(String libraryPath)
    : _libraryPath = libraryPath,
      _api = _NativeWebSocketApi.open(libraryPath) {
    if (_api.apiVersion() != _nativeApiVersion) {
      throw StateError('Unsupported ZEON Windows transport ABI');
    }
  }

  @visibleForTesting
  factory WinHttpWindowsSystemWebSocketTransport.forTesting(String libraryPath) =
      WinHttpWindowsSystemWebSocketTransport;

  final String _libraryPath;
  final _NativeWebSocketApi _api;

  @override
  Future<AdaptiveWebSocketConnection> connect(
    WindowsSystemWebSocketRequest request, {
    Future<Object?>? cancellation,
  }) async {
    final uri = Uri.parse(request.url);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError.value(uri.scheme, 'url', 'WinHTTP WebSocket supports only ws/wss');
    }
    final namedProxy = request.namedProxy?.trim();
    if (request.proxyMode == WindowsProxyMode.named && (namedProxy == null || namedProxy.isEmpty)) {
      throw ArgumentError.value(request.namedProxy, 'namedProxy', 'A named proxy endpoint is required');
    }

    final urlPointer = request.url.toNativeUtf16();
    final headersPointer = _serializeHeaders(request.headers).toNativeUtf16();
    final proxyPointer = namedProxy?.toNativeUtf16();
    late final int sessionId;
    try {
      sessionId = _api.connect(
        urlPointer,
        headersPointer,
        _clampedMilliseconds(request.timeout),
        request.receiveTimeout <= Duration.zero ? 0 : _clampedMilliseconds(request.receiveTimeout),
        request.proxyMode.index,
        proxyPointer ?? nullptr,
      );
    } finally {
      calloc.free(urlPointer);
      calloc.free(headersPointer);
      if (proxyPointer != null) calloc.free(proxyPointer);
    }
    if (sessionId == 0) {
      throw const WindowsSystemWebSocketUnavailableException();
    }

    final connection = _WinHttpWebSocketConnection(
      api: _api,
      libraryPath: _libraryPath,
      sessionId: sessionId,
      connectTimeout: request.timeout,
    );
    try {
      await connection.start(cancellation: cancellation);
      return connection;
    } catch (_) {
      await connection.abortConnect();
      rethrow;
    }
  }
}

class WindowsWebSocketNetworkException extends WindowsSystemNetworkException {
  const WindowsWebSocketNetworkException({
    required super.operation,
    required super.stage,
    required super.win32Code,
    required super.hresult,
    required this.httpUpgradeStatus,
    required this.proxyAuthStage,
    required this.closeCode,
  });

  final int? httpUpgradeStatus;
  final String? proxyAuthStage;
  final int? closeCode;
}

class _WinHttpWebSocketConnection implements AdaptiveWebSocketConnection {
  _WinHttpWebSocketConnection({
    required _NativeWebSocketApi api,
    required String libraryPath,
    required int sessionId,
    required Duration connectTimeout,
  }) : _api = api,
       _libraryPath = libraryPath,
       _sessionId = sessionId,
       _connectTimeout = connectTimeout;

  final _NativeWebSocketApi _api;
  final String _libraryPath;
  final int _sessionId;
  final Duration _connectTimeout;
  final StreamController<dynamic> _messages = StreamController<dynamic>(sync: true);
  final Completer<void> _connected = Completer<void>();
  final Completer<void> _done = Completer<void>();
  ReceivePort? _eventPort;
  ReceivePort? _errorPort;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _errorSubscription;
  Isolate? _pump;
  bool _closeStarted = false;
  bool _cancelled = false;
  int? closeCode;
  String? closeReason;

  Future<void> start({Future<Object?>? cancellation}) async {
    final eventPort = ReceivePort();
    final errorPort = ReceivePort();
    _eventPort = eventPort;
    _errorPort = errorPort;
    _eventSubscription = eventPort.listen(_handlePumpMessage);
    _pump = await Isolate.spawn<_WebSocketPumpInput>(
      _webSocketPumpMain,
      _WebSocketPumpInput(_libraryPath, _sessionId, eventPort.sendPort),
      onError: errorPort.sendPort,
      debugName: 'zeon-winhttp-websocket-events',
    );
    _errorSubscription = errorPort.listen((Object? error) {
      _api.cancel(_sessionId);
      _finishWithError(StateError('Windows WebSocket event worker terminated unexpectedly: ${_safeErrorLabel(error)}'));
    });
    Timer? timeoutTimer;
    timeoutTimer = Timer(_outerTimeout(_connectTimeout), () {
      if (_connected.isCompleted || _done.isCompleted) return;
      _api.cancel(_sessionId);
      _finishWithError(
        const WindowsWebSocketNetworkException(
          operation: 'websocket_connect_timeout',
          stage: WindowsNetworkFailureStage.connect,
          win32Code: 12002,
          hresult: 0x80072ee2,
          httpUpgradeStatus: null,
          proxyAuthStage: null,
          closeCode: null,
        ),
      );
    });
    cancellation?.then((Object? _) {
      if (_done.isCompleted) return;
      _cancelled = true;
      _api.cancel(_sessionId);
    });
    try {
      await _connected.future;
    } finally {
      timeoutTimer.cancel();
    }
  }

  Future<void> abortConnect() async {
    _api.cancel(_sessionId);
    try {
      await _done.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      _pump?.kill(priority: Isolate.immediate);
      _api.release(_sessionId);
      await _disposePorts();
    }
  }

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  Future<void> sendText(String value) => _send(Uint8List.fromList(utf8.encode(value)), binary: false);

  @override
  Future<void> sendBinary(Uint8List value) => _send(value, binary: true);

  Future<void> _send(Uint8List value, {required bool binary}) async {
    if (_done.isCompleted || _closeStarted) throw StateError('Windows WebSocket is closed');
    if (value.length > _maxMessageBytes) {
      throw ArgumentError.value(value.length, 'value', 'WebSocket message too large');
    }
    final buffer = value.isEmpty ? nullptr : calloc<Uint8>(value.length);
    try {
      if (value.isNotEmpty) buffer.asTypedList(value.length).setAll(0, value);
      final result = _api.send(_sessionId, buffer, value.length, binary ? 1 : 0);
      if (result != 0) {
        throw WindowsWebSocketNetworkException(
          operation: 'websocket_send',
          stage: WindowsNetworkFailureStage.unknown,
          win32Code: 0,
          hresult: 0,
          httpUpgradeStatus: 101,
          proxyAuthStage: null,
          closeCode: closeCode,
        );
      }
    } finally {
      if (buffer != nullptr) calloc.free(buffer);
    }
  }

  @override
  void setPingInterval(Duration? interval) {
    // WinHTTP responds to peer ping frames internally but exposes no API for
    // emitting a ping control frame. Receive timeout remains independently
    // bounded by the native transport.
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_done.isCompleted) return;
    if (!_closeStarted) {
      final reasonBytes = Uint8List.fromList(utf8.encode(reason ?? ''));
      if (reasonBytes.length > 123) {
        throw ArgumentError.value(reason, 'reason', 'WebSocket close reason exceeds 123 bytes');
      }
      _closeStarted = true;
      final buffer = reasonBytes.isEmpty ? nullptr : calloc<Uint8>(reasonBytes.length);
      try {
        if (reasonBytes.isNotEmpty) buffer.asTypedList(reasonBytes.length).setAll(0, reasonBytes);
        final result = _api.close(
          _sessionId,
          code ?? 1000,
          buffer,
          reasonBytes.length,
          _defaultShutdownTimeout.inMilliseconds,
        );
        if (result != 0) _api.cancel(_sessionId);
      } finally {
        if (buffer != nullptr) calloc.free(buffer);
      }
    }
    try {
      await _done.future.timeout(_outerTimeout(_defaultShutdownTimeout));
    } on TimeoutException {
      _api.cancel(_sessionId);
      await _done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
  }

  void _handlePumpMessage(Object? raw) {
    if (raw is! List<Object?> || raw.length != 10) {
      _finishWithError(StateError('Invalid Windows WebSocket event envelope'));
      return;
    }
    final type = raw[0]! as int;
    final operation = raw[1]! as int;
    final stage = raw[2]! as int;
    final code = raw[3]! as int;
    final httpStatus = raw[4]! as int;
    final nativeCloseCode = raw[5]! as int;
    final authStage = raw[6]! as int;
    final payload = raw[8]! as Uint8List;
    final terminal = raw[9]! as bool;
    try {
      switch (type) {
        case 1:
          if (!_connected.isCompleted) _connected.complete();
        case 2:
          _messages.add(utf8.decode(payload, allowMalformed: false));
        case 3:
          _messages.add(Uint8List.fromList(payload));
        case 4:
          closeCode = nativeCloseCode == 0 ? null : nativeCloseCode;
          closeReason = payload.isEmpty ? null : utf8.decode(payload, allowMalformed: true);
          _finishNormally();
        case 5:
          final error = WindowsWebSocketNetworkException(
            operation: _operationName(operation),
            stage: _failureStage(stage),
            win32Code: code,
            hresult: _hresultFromWin32(code),
            httpUpgradeStatus: httpStatus == 0 ? null : httpStatus,
            proxyAuthStage: _proxyAuthStage(authStage),
            closeCode: nativeCloseCode == 0 ? null : nativeCloseCode,
          );
          _finishWithError(_cancelled ? WindowsSystemRequestCancelledException(error) : error);
      }
    } catch (error, stackTrace) {
      _api.cancel(_sessionId);
      _finishWithError(error, stackTrace);
    }
    if (terminal && !_done.isCompleted) _finishNormally();
  }

  void _finishNormally() {
    if (!_connected.isCompleted) {
      _connected.completeError(
        const WindowsWebSocketNetworkException(
          operation: 'websocket_upgrade',
          stage: WindowsNetworkFailureStage.unknown,
          win32Code: 0,
          hresult: 0,
          httpUpgradeStatus: null,
          proxyAuthStage: null,
          closeCode: null,
        ),
      );
    }
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_done.isCompleted) _done.complete();
    unawaited(_disposePorts());
  }

  void _finishWithError(Object error, [StackTrace? stackTrace]) {
    if (_done.isCompleted) return;
    if (!_connected.isCompleted) _connected.completeError(error, stackTrace);
    if (!_messages.isClosed) {
      _messages.addError(error, stackTrace);
      unawaited(_messages.close());
    }
    if (!_done.isCompleted) _done.complete();
    unawaited(_disposePorts());
  }

  Future<void> _disposePorts() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _errorSubscription?.cancel();
    _errorSubscription = null;
    _eventPort?.close();
    _eventPort = null;
    _errorPort?.close();
    _errorPort = null;
  }
}

class _WebSocketPumpInput {
  const _WebSocketPumpInput(this.libraryPath, this.sessionId, this.resultPort);

  final String libraryPath;
  final int sessionId;
  final SendPort resultPort;
}

void _webSocketPumpMain(_WebSocketPumpInput input) {
  final api = _NativeWebSocketApi.open(input.libraryPath);
  final event = calloc<_NativeWebSocketEvent>()..ref.structSize = sizeOf<_NativeWebSocketEvent>();
  final payload = calloc<Uint8>(_maxMessageBytes);
  try {
    while (true) {
      event.ref.structSize = sizeOf<_NativeWebSocketEvent>();
      final result = api.nextEvent(input.sessionId, event, payload, _maxMessageBytes, _eventPollMilliseconds);
      if (result == 0) continue;
      if (result < 0) {
        api.cancel(input.sessionId);
        input.resultPort.send(<Object?>[5, 5, 6, 0, 0, 0, 0, 0, Uint8List(0), true]);
        return;
      }
      final length = event.ref.payloadLength;
      final bytes = length == 0 ? Uint8List(0) : Uint8List.fromList(payload.asTypedList(length));
      final terminal = event.ref.type == 4 || event.ref.type == 5;
      input.resultPort.send(<Object?>[
        event.ref.type,
        event.ref.operation,
        event.ref.failureStage,
        event.ref.win32Code,
        event.ref.httpStatus,
        event.ref.closeCode,
        event.ref.proxyAuthStage,
        event.ref.sequence,
        bytes,
        terminal,
      ]);
      if (terminal) return;
    }
  } finally {
    api.release(input.sessionId);
    calloc.free(payload);
    calloc.free(event);
  }
}

final class _NativeWebSocketEvent extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int type;

  @Uint32()
  external int operation;

  @Uint32()
  external int failureStage;

  @Uint32()
  external int win32Code;

  @Uint32()
  external int httpStatus;

  @Uint32()
  external int closeCode;

  @Uint32()
  external int proxyAuthStage;

  @Uint32()
  external int payloadLength;

  @Uint32()
  external int reserved;

  @Uint64()
  external int sequence;
}

class _NativeWebSocketApi {
  _NativeWebSocketApi._(DynamicLibrary library)
    : apiVersion = library.lookupFunction<Uint32 Function(), int Function()>('zeon_ws_api_version'),
      connect = library.lookupFunction<_ConnectNative, _ConnectDart>('zeon_ws_connect'),
      nextEvent = library.lookupFunction<_NextEventNative, _NextEventDart>('zeon_ws_next_event'),
      send = library.lookupFunction<_SendNative, _SendDart>('zeon_ws_send'),
      close = library.lookupFunction<_CloseNative, _CloseDart>('zeon_ws_close'),
      cancel = library.lookupFunction<Void Function(Uint64), void Function(int)>('zeon_ws_cancel'),
      release = library.lookupFunction<Void Function(Uint64), void Function(int)>('zeon_ws_release'),
      preferredProxyAuthScheme = library.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'zeon_ws_preferred_proxy_auth_scheme',
      ),
      classifyFailureStage = library
          .lookupFunction<Uint32 Function(Uint32, Uint32, Uint32), int Function(int, int, int)>(
            'zeon_ws_classify_failure_stage',
          );

  factory _NativeWebSocketApi.open(String path) => _NativeWebSocketApi._(DynamicLibrary.open(path));

  final int Function() apiVersion;
  final _ConnectDart connect;
  final _NextEventDart nextEvent;
  final _SendDart send;
  final _CloseDart close;
  final void Function(int) cancel;
  final void Function(int) release;
  final int Function(int) preferredProxyAuthScheme;
  final int Function(int, int, int) classifyFailureStage;
}

typedef _ConnectNative = Uint64 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32, Uint32, Uint32, Pointer<Utf16>);
typedef _ConnectDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int, int, int, Pointer<Utf16>);
typedef _NextEventNative = Int32 Function(Uint64, Pointer<_NativeWebSocketEvent>, Pointer<Uint8>, Uint32, Uint32);
typedef _NextEventDart = int Function(int, Pointer<_NativeWebSocketEvent>, Pointer<Uint8>, int, int);
typedef _SendNative = Int32 Function(Uint64, Pointer<Uint8>, Uint32, Uint32);
typedef _SendDart = int Function(int, Pointer<Uint8>, int, int);
typedef _CloseNative = Int32 Function(Uint64, Uint16, Pointer<Uint8>, Uint32, Uint32);
typedef _CloseDart = int Function(int, int, Pointer<Uint8>, int, int);

String _resolveTransportLibrary() {
  final override = Platform.environment['ZEON_WINDOWS_TRANSPORT_DLL']?.trim();
  final candidates = <String>[
    if (override != null && override.isNotEmpty) override,
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}zeon_windows_transport.dll',
  ];
  for (final candidate in candidates) {
    final file = File(candidate).absolute;
    if (file.existsSync()) return file.path;
  }
  throw StateError('ZEON Windows transport DLL is unavailable');
}

String _serializeHeaders(Map<String, String> headers) {
  const forbidden = <String>{
    'connection',
    'upgrade',
    'host',
    'content-length',
    'sec-websocket-key',
    'sec-websocket-version',
    'sec-websocket-extensions',
  };
  final lines = <String>[];
  for (final entry in headers.entries) {
    final name = entry.key.trim();
    final value = entry.value.trim();
    if (name.isEmpty || forbidden.contains(name.toLowerCase())) continue;
    if (name.contains(RegExp(r'[\r\n:]')) || value.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Invalid WebSocket header');
    }
    lines.add('$name: $value');
  }
  return lines.join('\r\n');
}

Duration _outerTimeout(Duration phaseTimeout) {
  final milliseconds = phaseTimeout.inMilliseconds.clamp(1, 0x1fffffff);
  final grace = (milliseconds ~/ 10).clamp(250, 1500);
  return Duration(milliseconds: milliseconds + grace);
}

int _clampedMilliseconds(Duration value) => value.inMilliseconds.clamp(1, 0x7fffffff);

int _hresultFromWin32(int code) => code <= 0 ? code : (code & 0xffff) | 0x80070000;

WindowsNetworkFailureStage _failureStage(int value) => switch (value) {
  1 => WindowsNetworkFailureStage.dns,
  2 => WindowsNetworkFailureStage.connect,
  3 => WindowsNetworkFailureStage.tls,
  4 => WindowsNetworkFailureStage.proxy,
  5 => WindowsNetworkFailureStage.http,
  6 => WindowsNetworkFailureStage.websocket,
  _ => WindowsNetworkFailureStage.unknown,
};

@visibleForTesting
int winHttpWebSocketPreferredProxyAuthSchemeForTesting(String libraryPath, int supportedSchemes) =>
    _NativeWebSocketApi.open(libraryPath).preferredProxyAuthScheme(supportedSchemes);

@visibleForTesting
WindowsNetworkFailureStage classifyWinHttpWebSocketFailureForTesting(
  String libraryPath,
  int code,
  int operation, {
  bool secure = false,
}) => _failureStage(_NativeWebSocketApi.open(libraryPath).classifyFailureStage(code, operation, secure ? 1 : 0));

String _operationName(int value) => switch (value) {
  1 => 'websocket_open',
  2 => 'websocket_send_request',
  3 => 'websocket_receive_response',
  4 => 'websocket_upgrade',
  5 => 'websocket_receive',
  6 => 'websocket_send',
  7 => 'websocket_shutdown',
  8 => 'websocket_close',
  9 => 'websocket_timeout',
  10 => 'websocket_cancel',
  11 => 'websocket_proxy_auth',
  _ => 'websocket',
};

String? _proxyAuthStage(int value) => switch (value) {
  1 => 'retrying',
  2 => 'failed',
  _ => null,
};

String _safeErrorLabel(Object? error) =>
    error is List && error.isNotEmpty ? error.first.runtimeType.toString() : error.runtimeType.toString();
