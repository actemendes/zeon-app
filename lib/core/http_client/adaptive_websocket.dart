import 'dart:io';
import 'dart:typed_data';

import 'package:zeon/core/http_client/windows_system_http_transport.dart';

abstract interface class AdaptiveWebSocketConnection {
  Stream<dynamic> get messages;

  Future<void> sendText(String value);

  Future<void> sendBinary(Uint8List value);

  void setPingInterval(Duration? interval);

  Future<void> close([int? code, String? reason]);
}

class DartAdaptiveWebSocketConnection implements AdaptiveWebSocketConnection {
  DartAdaptiveWebSocketConnection(this._socket, this._client);

  final WebSocket _socket;
  final HttpClient _client;
  bool _closed = false;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  Future<void> sendText(String value) async => _socket.add(value);

  @override
  Future<void> sendBinary(Uint8List value) async => _socket.add(value);

  @override
  void setPingInterval(Duration? interval) => _socket.pingInterval = interval;

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.close(code, reason);
    } finally {
      _client.close(force: true);
    }
  }
}

class WindowsSystemWebSocketRequest {
  const WindowsSystemWebSocketRequest({
    required this.url,
    required this.headers,
    required this.timeout,
    this.receiveTimeout = const Duration(minutes: 2),
    this.proxyMode = WindowsProxyMode.automatic,
    this.namedProxy,
  });

  final String url;
  final Map<String, String> headers;
  final Duration timeout;
  final Duration receiveTimeout;
  final WindowsProxyMode proxyMode;
  final String? namedProxy;
}

abstract interface class WindowsSystemWebSocketTransport {
  Future<AdaptiveWebSocketConnection> connect(WindowsSystemWebSocketRequest request, {Future<Object?>? cancellation});
}

class WindowsSystemWebSocketUnavailableException extends WindowsSystemNetworkException {
  const WindowsSystemWebSocketUnavailableException()
    : super(operation: 'websocket_upgrade', stage: WindowsNetworkFailureStage.unknown, win32Code: 0, hresult: 0);
}

class AdaptiveWebSocketRoute {
  const AdaptiveWebSocketRoute({required this.connection, required this.routeMode, required this.usesLocalZeonProxy});

  final AdaptiveWebSocketConnection connection;
  final String routeMode;
  final bool usesLocalZeonProxy;
}
