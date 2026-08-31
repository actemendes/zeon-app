import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:meta/meta.dart';

import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/http_client/windows_network_diagnostics.dart';
import 'package:zeon/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  static const localZeonProxyHost = '127.0.0.1';

  final Map<String, Dio> _dio = {};
  DioHttpClient({
    required Duration timeout,
    required this.userAgent,
    required bool debug,
    Future<bool> Function()? requestVpnRecovery,
    Future<bool> Function(String host, int port)? proxyProbe,
    bool Function(String url)? controlPlaneMatcher,
    bool? isWindows,
    WindowsSystemHttpTransport? windowsSystemTransport,
    WindowsSystemWebSocketTransport? windowsSystemWebSocketTransport,
  }) : _requestVpnRecovery = requestVpnRecovery,
       _proxyProbe = proxyProbe,
       _controlPlaneMatcher = controlPlaneMatcher ?? MobileApiProxyRoute.requiresVpn,
       _isWindows = isWindows ?? Platform.isWindows,
       _timeout = timeout,
       _windowsSystemTransport = windowsSystemTransport,
       _windowsSystemWebSocketTransport = windowsSystemWebSocketTransport {
    for (final mode in ["proxy", "direct"]) {
      _dio[mode] = Dio(
        BaseOptions(
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          headers: {"User-Agent": userAgent},
        ),
      );
      _dio[mode]!.interceptors.add(
        RetryInterceptor(
          dio: _dio[mode]!,
          retryDelays: [
            const Duration(seconds: 1),
            if (mode != "proxy") ...[const Duration(seconds: 2), const Duration(seconds: 3)],
          ],
        ),
      );

      _dio[mode]!.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          // dart:io presets `user-agent` on an auto-redirect request from
          // HttpClient.userAgent and then copies the original headers only
          // where they are still unset, so a per-request User-Agent is
          // silently replaced by `Dart/x.y (dart:io)` on every redirect hop.
          // Subscription endpoints negotiate their response format on this
          // header, so losing it downgrades a redirected download to the
          // legacy format that carries no TLS trust material.
          client.userAgent = userAgent;
          client.findProxy = (_) =>
              mode == "proxy" ? "PROXY ${_isWindows ? localZeonProxyHost : 'localhost'}:$port" : "DIRECT";
          return client;
        },
      );
    }

    if (debug) {
      // _dio.interceptors.add(LoggyDioInterceptor(requestHeader: true));
    }
  }

  int port = 0;
  bool? _vpnActive;

  String userAgent;
  final Future<bool> Function()? _requestVpnRecovery;
  final Future<bool> Function(String host, int port)? _proxyProbe;
  final bool Function(String url) _controlPlaneMatcher;
  final bool _isWindows;
  final Duration _timeout;
  final WindowsSystemHttpTransport? _windowsSystemTransport;
  final WindowsSystemWebSocketTransport? _windowsSystemWebSocketTransport;

  Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 300)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      await socket.close();
      return true;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  void setProxyPort(int port) {
    this.port = port;
    loggy.debug("setting proxy port: [$port]");
  }

  /// Supplies the UI connection state. A null value (background isolate or
  /// early bootstrap) falls back to probing the local proxy.
  void setVpnActive(bool active) {
    _vpnActive = active;
    loggy.debug("setting VPN transport state: [$active]");
  }

  /// Legacy client factory retained for non-Windows/local-proxy callers.
  /// Windows system-network WebSockets must not silently degrade to Dart
  /// `DIRECT`, because that bypasses Windows proxy/PAC semantics.
  Future<AdaptiveHttpClientRoute> createAdaptiveHttpClient(String url) async {
    final mode = await _resolveMode(url: url, directOnly: false, proxyOnly: false);
    if (_isWindows && mode == HttpRouteMode.systemNetwork) {
      throw const WindowsSystemWebSocketUnavailableException();
    }
    final client = HttpClient();
    client.userAgent = userAgent;
    client.findProxy = (_) => mode == HttpRouteMode.localZeonProxy ? "PROXY $localZeonProxyHost:$port" : "DIRECT";
    return AdaptiveHttpClientRoute(client: client, usesProxy: mode == HttpRouteMode.localZeonProxy);
  }

  Future<AdaptiveWebSocketRoute> openWebSocket(
    String url, {
    Map<String, String>? headers,
    CancelToken? cancelToken,
    bool directOnly = false,
    bool proxyOnly = false,
  }) async {
    final mode = await _resolveMode(url: url, directOnly: directOnly, proxyOnly: proxyOnly);
    if (_isWindows && mode == HttpRouteMode.systemNetwork) {
      final transport = _windowsSystemWebSocketTransport;
      if (transport == null) throw const WindowsSystemWebSocketUnavailableException();
      final connection = await transport.connect(
        WindowsSystemWebSocketRequest(
          url: url,
          headers: <String, String>{'User-Agent': userAgent, if (headers != null) ...headers},
          timeout: _timeout,
        ),
        cancellation: cancelToken?.whenCancel,
      );
      return AdaptiveWebSocketRoute(connection: connection, routeMode: mode.name, usesLocalZeonProxy: false);
    }

    final client = HttpClient()..userAgent = userAgent;
    client.findProxy = (_) => mode == HttpRouteMode.localZeonProxy ? 'PROXY $localZeonProxyHost:$port' : 'DIRECT';
    try {
      final socket = await WebSocket.connect(url, headers: headers, customClient: client);
      return AdaptiveWebSocketRoute(
        connection: DartAdaptiveWebSocketConnection(socket, client),
        routeMode: mode.name,
        usesLocalZeonProxy: mode == HttpRouteMode.localZeonProxy,
      );
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    String? operation,
  }) {
    return _sendAdaptive(
      url: url,
      operation: operation ?? 'http_get',
      directOnly: directOnly,
      proxyOnly: proxyOnly,
      send: (mode) => _dio[mode]!.get<T>(
        url,
        cancelToken: cancelToken,
        options: _options(
          url,
          userAgent: userAgent,
          credentials: credentials,
          headers: headers,
          disableRetry: disableRetry,
        ),
      ),
      sendSystem: () => _sendSystem<T>(
        method: 'GET',
        url: url,
        cancelToken: cancelToken,
        requestUserAgent: userAgent,
        credentials: credentials,
        headers: headers,
      ),
    );
  }

  Future<Response<T>> post<T>(
    String url, {
    dynamic data,
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    String? operation,
  }) {
    return _sendAdaptive(
      url: url,
      operation: operation ?? 'http_post',
      directOnly: directOnly,
      proxyOnly: proxyOnly,
      send: (mode) => _dio[mode]!.post<T>(
        url,
        data: data,
        cancelToken: cancelToken,
        options: _options(
          url,
          userAgent: userAgent,
          credentials: credentials,
          headers: headers,
          disableRetry: disableRetry,
        ),
      ),
      sendSystem: () => _sendSystem<T>(
        method: 'POST',
        url: url,
        data: data,
        cancelToken: cancelToken,
        requestUserAgent: userAgent,
        credentials: credentials,
        headers: headers,
      ),
    );
  }

  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    String? operation,
  }) {
    return _sendAdaptive(
      url: url,
      operation: operation ?? 'http_download',
      directOnly: directOnly,
      proxyOnly: proxyOnly,
      send: (mode) => _dio[mode]!.download(
        url,
        path,
        cancelToken: cancelToken,
        options: _options(
          url,
          userAgent: userAgent,
          credentials: credentials,
          headers: headers,
          disableRetry: disableRetry,
        ),
      ),
      sendSystem: () => _downloadSystem(
        url: url,
        path: path,
        cancelToken: cancelToken,
        requestUserAgent: userAgent,
        credentials: credentials,
        headers: headers,
      ),
    );
  }

  Future<T> _sendAdaptive<T>({
    required String url,
    required String operation,
    required bool directOnly,
    required bool proxyOnly,
    required Future<T> Function(String mode) send,
    Future<T> Function()? sendSystem,
  }) async {
    final mode = await _resolveMode(url: url, directOnly: directOnly, proxyOnly: proxyOnly);
    final dioMode = mode == HttpRouteMode.localZeonProxy ? "proxy" : "direct";
    try {
      if (mode == HttpRouteMode.systemNetwork) {
        if (_windowsSystemTransport == null || sendSystem == null) {
          throw const WindowsSystemNetworkException(
            operation: 'transport_unavailable',
            stage: WindowsNetworkFailureStage.unknown,
            win32Code: 0,
            hresult: 0,
          );
        }
        return await sendSystem();
      }
      return await send(dioMode);
    } catch (error, stackTrace) {
      if (_isWindows) {
        final ready = mode == HttpRouteMode.localZeonProxy ? await _isProxyAvailable() : false;
        loggy.warning(
          jsonEncode(
            windowsNetworkDiagnostic(
              routeMode: mode,
              operation: operation,
              error: error,
              vpnActive: _vpnActive,
              localProxyReady: ready,
            ),
          ),
        );
      }
      final recovered =
          !directOnly && mode != HttpRouteMode.localZeonProxy && await recoverWithVpnAfterFailure(url, error);
      if (recovered && await waitForProxyAvailable()) {
        loggy.info("retrying control-plane request through VPN proxy");
        return send("proxy");
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<Response<T>> _sendSystem<T>({
    required String method,
    required String url,
    dynamic data,
    CancelToken? cancelToken,
    String? requestUserAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
  }) async {
    final transport = _windowsSystemTransport;
    if (transport == null) throw StateError('Windows system transport is unavailable');
    if (cancelToken?.isCancelled ?? false) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: url),
        reason: cancelToken?.cancelError,
      );
    }
    final requestOptions = RequestOptions(path: url, method: method);
    try {
      final response = await transport.send(
        WindowsSystemHttpRequest(
          method: method,
          url: url,
          headers: _systemHeaders(
            requestUserAgent: requestUserAgent,
            credentials: credentials,
            headers: headers,
            hasBody: data != null,
          ),
          timeout: _timeout,
          body: _systemBody(data),
        ),
        cancellation: cancelToken?.whenCancel,
      );
      if (cancelToken?.isCancelled ?? false) {
        throw DioException.requestCancelled(requestOptions: requestOptions, reason: cancelToken?.cancelError);
      }
      final responseRequestOptions = RequestOptions(path: response.finalUrl, method: method);
      final result = Response<T>(
        requestOptions: responseRequestOptions,
        statusCode: response.statusCode,
        headers: Headers.fromMap(response.headers),
        data: _decodeSystemBody<T>(response.body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DioException.badResponse(
          statusCode: response.statusCode,
          requestOptions: responseRequestOptions,
          response: result,
        );
      }
      return result;
    } on WindowsSystemRequestCancelledException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DioException.requestCancelled(requestOptions: requestOptions, reason: error.reason),
        stackTrace,
      );
    } on WindowsSystemNetworkException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        DioException.connectionError(reason: error.toString(), requestOptions: requestOptions, error: error),
        stackTrace,
      );
    }
  }

  Future<Response> _downloadSystem({
    required String url,
    required String path,
    CancelToken? cancelToken,
    String? requestUserAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
  }) async {
    final response = await _sendSystem<Uint8List>(
      method: 'GET',
      url: url,
      cancelToken: cancelToken,
      requestUserAgent: requestUserAgent,
      credentials: credentials,
      headers: headers,
    );
    await File(path).writeAsBytes(response.data ?? const <int>[], flush: true);
    return response;
  }

  Map<String, String> _systemHeaders({
    String? requestUserAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    required bool hasBody,
  }) {
    final result = <String, String>{
      'User-Agent': requestUserAgent ?? userAgent,
      if (hasBody) 'Content-Type': 'application/json',
      if (headers != null) ...headers,
    };
    final userInfo = credentials == null ? null : '${credentials.username}:${credentials.password}';
    if (userInfo != null) result['Authorization'] = 'Basic ${base64.encode(utf8.encode(userInfo))}';
    return result;
  }

  Uint8List? _systemBody(dynamic data) {
    if (data == null) return null;
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    return Uint8List.fromList(utf8.encode(jsonEncode(data)));
  }

  T? _decodeSystemBody<T>(Uint8List bytes) {
    if (T.toString() == 'void') return null;
    if (T == Uint8List) return bytes as T;
    final text = utf8.decode(bytes, allowMalformed: true);
    if (T == String) return text as T;
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded as T;
    } on FormatException {
      if (T == dynamic || T == Object) return text as T;
      rethrow;
    }
  }

  /// Requests user-assisted VPN recovery only for a real control-plane network
  /// failure. HTTP responses (including 4xx/5xx) are not connectivity failures.
  Future<bool> recoverWithVpnAfterFailure(String url, Object error) async {
    final recovery = _requestVpnRecovery;
    if (recovery == null || !_controlPlaneMatcher(url) || !_isNetworkFailure(error)) {
      return false;
    }
    return recovery();
  }

  Future<bool> waitForProxyAvailable({Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (await _isProxyAvailable()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    } while (DateTime.now().isBefore(deadline));
    return false;
  }

  @visibleForTesting
  Future<HttpRouteMode> resolveRouteForTesting({
    required String url,
    bool directOnly = false,
    bool proxyOnly = false,
  }) => _resolveMode(url: url, directOnly: directOnly, proxyOnly: proxyOnly);

  Future<HttpRouteMode> _resolveMode({required String url, required bool directOnly, required bool proxyOnly}) async {
    if (!_isWindows) {
      // Preserve the established Android/iOS/other-platform contract in this
      // Windows-only change set.
      if (_controlPlaneMatcher(url)) return _adaptiveMode();
      if (directOnly) return HttpRouteMode.forcedDirect;
      if (proxyOnly) {
        if (!await _isProxyAvailable()) throw const VpnProxyUnavailableException();
        return HttpRouteMode.localZeonProxy;
      }
      return _adaptiveMode();
    }

    if (directOnly && proxyOnly) {
      throw ArgumentError('directOnly and proxyOnly are mutually exclusive');
    }

    if (proxyOnly) {
      if (!await _isProxyAvailable()) {
        throw const VpnProxyUnavailableException();
      }
      loggy.debug("using required local proxy [port=$port]");
      return HttpRouteMode.localZeonProxy;
    }
    if (directOnly) {
      return _isWindows ? HttpRouteMode.systemNetwork : HttpRouteMode.forcedDirect;
    }
    if (_controlPlaneMatcher(url)) {
      final mode = await _adaptiveMode();
      loggy.debug("using adaptive control-plane mode [$mode, port=$port]");
      return mode;
    }
    final mode = await _adaptiveMode();
    loggy.debug("using HTTP mode [$mode, port=$port]");
    return mode;
  }

  Future<HttpRouteMode> _adaptiveMode() async {
    if (_vpnActive == false) return _ordinaryNetworkMode;
    if (_vpnActive == true) {
      if (await waitForProxyAvailable(timeout: const Duration(seconds: 3))) {
        return HttpRouteMode.localZeonProxy;
      }
      throw const VpnProxyUnavailableException();
    }
    // On Windows an unknown early-bootstrap state must never attach to a stale
    // or unrelated loopback listener. Use the OS networking path until the app
    // has positively observed a Connected core.
    if (_isWindows) return HttpRouteMode.systemNetwork;
    return await _isProxyAvailable() ? HttpRouteMode.localZeonProxy : _ordinaryNetworkMode;
  }

  HttpRouteMode get _ordinaryNetworkMode => _isWindows ? HttpRouteMode.systemNetwork : HttpRouteMode.forcedDirect;

  Future<bool> _isProxyAvailable() async {
    final proxyPort = port;
    if (proxyPort <= 0) return false;
    final probe = _proxyProbe;
    return probe != null ? probe(localZeonProxyHost, proxyPort) : isPortOpen(localZeonProxyHost, proxyPort);
  }

  bool _isNetworkFailure(Object error) {
    if (error is SocketException || error is HandshakeException) return true;
    if (error is! DioException) return false;
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.unknown => error.error is SocketException || error.error is HandshakeException,
      _ => false,
    };
  }

  Options _options(
    String url, {
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool disableRetry = false,
  }) {
    final uri = Uri.parse(url);

    String? userInfo;
    if (credentials != null) {
      userInfo = "${credentials.username}:${credentials.password}";
    } else if (uri.userInfo.isNotEmpty) {
      userInfo = uri.userInfo;
    }

    String? basicAuth;
    if (userInfo != null) {
      basicAuth = "Basic ${base64.encode(utf8.encode(userInfo))}";
    }

    final options = Options(
      headers: {
        if (userAgent != null) "User-Agent": userAgent,
        if (basicAuth != null) "authorization": basicAuth,
        if (headers != null) ...headers,
        // "Accept": "application/json",
        // "Content-Type": "application/json",
      },
    );
    // A control-plane request gets one normal attempt followed by one explicit
    // VPN recovery attempt. Hidden interceptor retries would delay the prompt.
    if (disableRetry || _controlPlaneMatcher(url)) {
      options.disableRetry = true;
    }
    return options;
  }
}

enum HttpRouteMode { localZeonProxy, systemNetwork, forcedDirect }

class AdaptiveHttpClientRoute {
  const AdaptiveHttpClientRoute({required this.client, required this.usesProxy});

  final HttpClient client;
  final bool usesProxy;
}

class VpnProxyUnavailableException implements Exception {
  const VpnProxyUnavailableException();

  @override
  String toString() => 'VPN proxy is unavailable';
}
