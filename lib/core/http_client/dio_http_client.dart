import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';

import 'package:zeon/core/http_client/mobile_api_proxy_route.dart';
import 'package:zeon/utils/custom_loggers.dart';

class DioHttpClient with InfraLogger {
  final Map<String, Dio> _dio = {};
  DioHttpClient({
    required Duration timeout,
    required this.userAgent,
    required bool debug,
    Future<bool> Function()? requestVpnRecovery,
    Future<bool> Function(String host, int port)? proxyProbe,
    bool Function(String url)? controlPlaneMatcher,
  }) : _requestVpnRecovery = requestVpnRecovery,
       _proxyProbe = proxyProbe,
       _controlPlaneMatcher = controlPlaneMatcher ?? MobileApiProxyRoute.requiresVpn {
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
          client.findProxy = (_) => mode == "proxy" ? "PROXY localhost:$port" : "DIRECT";
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

  /// Creates a WebSocket client matching the current transport state.
  ///
  /// A running local VPN proxy is always used without a DIRECT fallback.
  /// Otherwise the connection is made directly.
  Future<AdaptiveHttpClientRoute> createAdaptiveHttpClient(String url) async {
    final mode = await _resolveMode(url: url, directOnly: false, proxyOnly: false);
    final client = HttpClient();
    client.userAgent = userAgent;
    client.findProxy = (_) => mode == "proxy" ? "PROXY 127.0.0.1:$port" : "DIRECT";
    return AdaptiveHttpClientRoute(client: client, usesProxy: mode == "proxy");
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
  }) {
    return _sendAdaptive(
      url: url,
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
  }) {
    return _sendAdaptive(
      url: url,
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
  }) {
    return _sendAdaptive(
      url: url,
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
    );
  }

  Future<T> _sendAdaptive<T>({
    required String url,
    required bool directOnly,
    required bool proxyOnly,
    required Future<T> Function(String mode) send,
  }) async {
    final mode = await _resolveMode(url: url, directOnly: directOnly, proxyOnly: proxyOnly);
    try {
      return await send(mode);
    } catch (error, stackTrace) {
      final recovered = mode == "direct" && await recoverWithVpnAfterFailure(url, error);
      if (recovered && await waitForProxyAvailable()) {
        loggy.info("retrying control-plane request through VPN proxy");
        return send("proxy");
      }
      Error.throwWithStackTrace(error, stackTrace);
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

  Future<String> _resolveMode({required String url, required bool directOnly, required bool proxyOnly}) async {
    if (_controlPlaneMatcher(url)) {
      final mode = await _adaptiveMode();
      loggy.debug("using adaptive control-plane mode [$mode, port=$port]");
      return mode;
    }
    if (directOnly) return "direct";
    if (proxyOnly) {
      if (!await _isProxyAvailable()) {
        throw const VpnProxyUnavailableException();
      }
      loggy.debug("using required local proxy [port=$port]");
      return "proxy";
    }
    final mode = await _adaptiveMode();
    loggy.debug("using HTTP mode [$mode, port=$port]");
    return mode;
  }

  Future<String> _adaptiveMode() async {
    if (_vpnActive == false) return "direct";
    if (_vpnActive == true) {
      if (await waitForProxyAvailable(timeout: const Duration(seconds: 3))) return "proxy";
      throw const VpnProxyUnavailableException();
    }
    return await _isProxyAvailable() ? "proxy" : "direct";
  }

  Future<bool> _isProxyAvailable() async {
    final proxyPort = port;
    if (proxyPort <= 0) return false;
    final probe = _proxyProbe;
    return probe != null ? probe("127.0.0.1", proxyPort) : isPortOpen("127.0.0.1", proxyPort);
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
