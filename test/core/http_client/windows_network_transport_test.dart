import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/local_zeon_proxy_readiness.dart';
import 'package:zeon/core/http_client/windows_network_diagnostics.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';

void main() {
  group('Windows system network transport', () {
    test('prefers Negotiate, then NTLM, and never guesses Basic proxy credentials', () {
      expect(preferredIntegratedAuthSchemeForTesting(0x10 | 0x02 | 0x01), 0x10);
      expect(preferredIntegratedAuthSchemeForTesting(0x02 | 0x01), 0x02);
      expect(preferredIntegratedAuthSchemeForTesting(0x01), 0);
      expect(shouldRetryIntegratedProxyAuthForTesting(407, false), isTrue);
      expect(shouldRetryIntegratedProxyAuthForTesting(407, true), isFalse);
      expect(shouldRetryIntegratedProxyAuthForTesting(403, false), isFalse);
    });

    test('uses WinHTTP and returns response metadata without disabling TLS validation', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });

      final response = await const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: 'http://127.0.0.1:${server.port}/health',
          headers: const {'User-Agent': 'ZEON-test'},
          timeout: const Duration(seconds: 3),
        ),
      );

      expect(response.statusCode, 200);
      expect(jsonDecode(utf8.decode(response.body)), {'ok': true});
      expect(response.finalUrl, startsWith('http://127.0.0.1:${server.port}/'));
    }, skip: !Platform.isWindows);

    test('slow WinHTTP response runs off the UI isolate without deadlock', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        request.response.write('slow-ok');
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });

      var uiTicks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 20), (_) => uiTicks++);
      addTearDown(timer.cancel);
      final response = await const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: 'http://127.0.0.1:${server.port}/slow',
          headers: const {},
          timeout: const Duration(seconds: 2),
        ),
      );

      expect(utf8.decode(response.body), 'slow-ok');
      expect(uiTicks, greaterThanOrEqualTo(5));
    }, skip: !Platform.isWindows);

    test('response watchdog is a structured bounded WinHTTP failure', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });

      await expectLater(
        const WinHttpWindowsSystemTransport().send(
          WindowsSystemHttpRequest(
            method: 'GET',
            url: 'http://127.0.0.1:${server.port}/timeout',
            headers: const {},
            timeout: const Duration(milliseconds: 120),
          ),
        ),
        throwsA(
          isA<WindowsSystemNetworkException>()
              .having((error) => error.win32Code, 'win32Code', 12002)
              .having((error) => error.operation, 'operation', 'overall_timeout')
              .having((error) => error.stage, 'stage', WindowsNetworkFailureStage.unknown),
        ),
      );
    }, skip: !Platform.isWindows);

    test('cancellation completes promptly while a worker is blocked in receive', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });
      final cancelled = Completer<Object?>();
      final stopwatch = Stopwatch()..start();
      final request = const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: 'http://127.0.0.1:${server.port}/cancel',
          headers: const {},
          timeout: const Duration(seconds: 2),
        ),
        cancellation: cancelled.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      cancelled.complete('test cancellation');

      await expectLater(request, throwsA(isA<WindowsSystemRequestCancelledException>()));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    }, skip: !Platform.isWindows);

    test('sequential isolated WinHTTP workers close cleanly', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        request.response.write('${++requests}');
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });

      for (var expected = 1; expected <= 5; expected++) {
        final response = await const WinHttpWindowsSystemTransport().send(
          WindowsSystemHttpRequest(
            method: 'GET',
            url: 'http://127.0.0.1:${server.port}/sequence',
            headers: const {},
            timeout: const Duration(seconds: 2),
          ),
        );
        expect(utf8.decode(response.body), '$expected');
      }
    }, skip: !Platform.isWindows);

    test('connect timeout classification remains structured', () {
      expect(classifyWinHttpFailureStageForTesting(12002, 'connect'), WindowsNetworkFailureStage.connect);
      expect(classifyWinHttpFailureStageForTesting(12002, 'receive'), WindowsNetworkFailureStage.http);
    });

    test('certificate failures are classified as TLS failures', () {
      for (final code in const [12037, 12038, 12044, 12045, 12157, 12169, 12170, 12175]) {
        expect(
          classifyWinHttpFailureStageForTesting(code, 'receive'),
          WindowsNetworkFailureStage.tls,
          reason: 'WinHTTP error $code must not be reported as a generic HTTP failure',
        );
      }
    });

    test('untrusted local TLS certificate is rejected by Windows validation', () async {
      final context = SecurityContext()
        ..useCertificateChain('hiddify-core/hiddify-sing-box/replace/psiphon-quic-go/internal/testdata/cert.pem')
        ..usePrivateKey('hiddify-core/hiddify-sing-box/replace/psiphon-quic-go/internal/testdata/priv.key');
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
      final subscription = server.listen((request) async {
        request.response.write('must-not-be-accepted');
        await request.response.close();
      });
      addTearDown(() async {
        await server.close(force: true);
        await subscription.cancel();
      });

      await expectLater(
        const WinHttpWindowsSystemTransport().send(
          WindowsSystemHttpRequest(
            method: 'GET',
            url: 'https://127.0.0.1:${server.port}/untrusted',
            headers: const {},
            timeout: const Duration(seconds: 2),
            proxyMode: WindowsProxyMode.direct,
          ),
        ),
        throwsA(
          isA<WindowsSystemNetworkException>().having((error) => error.stage, 'stage', WindowsNetworkFailureStage.tls),
        ),
      );
    }, skip: !Platform.isWindows);

    test('WinHTTP source contains no certificate-validation bypass', () async {
      final source = await File('lib/core/http_client/windows_system_http_transport.dart').readAsString();
      expect(source, isNot(contains('badCertificateCallback')));
      expect(source, isNot(contains('SECURITY_FLAG_IGNORE')));
      expect(source, isNot(contains('WINHTTP_OPTION_SECURITY_FLAGS')));
    });

    test('accepts a same-process listener as ZEON-owned readiness', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) {
        socket.listen((data) {
          if (data.length >= 3 && data[0] == 0x05) socket.add(const <int>[0x05, 0x00]);
        });
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
      });

      expect(await isLocalZeonProxyReady('127.0.0.1', server.port), isTrue);
    }, skip: !Platform.isWindows);

    test('rejects an unrelated same-process TCP listener and IPv6 localhost', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) => socket.close());
      addTearDown(() async {
        await subscription.cancel();
        await server.close();
      });

      expect(await isLocalZeonProxyReady('127.0.0.1', server.port), isFalse);
      expect(await isLocalZeonProxyReady('localhost', server.port), isFalse);
      expect(await isLocalZeonProxyReady('::1', server.port), isFalse);
    }, skip: !Platform.isWindows);

    test('port closure after readiness is a normal proxy failure without fallback', () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();
      var recoveryCalls = 0;
      final client =
          DioHttpClient(
              timeout: const Duration(milliseconds: 250),
              userAgent: 'ZEON-test',
              debug: false,
              isWindows: true,
              controlPlaneMatcher: (_) => true,
              proxyProbe: (_, _) async => true,
              requestVpnRecovery: () async {
                recoveryCalls++;
                return true;
              },
            )
            ..setProxyPort(port)
            ..setVpnActive(true);

      await expectLater(
        client.get<void>('http://proxy-target.invalid/race', proxyOnly: true, disableRetry: true),
        throwsA(isA<DioException>()),
      );
      expect(recoveryCalls, 0);
    });

    test('rejects a foreign process listening on mixed-port', () async {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);'
            r'$l.Start();[Console]::Out.WriteLine(([Net.IPEndPoint]$l.LocalEndpoint).Port);'
            r'[Console]::Out.Flush();[Console]::In.ReadLine()|Out-Null;$l.Stop()',
      ]);
      addTearDown(() async {
        process.stdin.writeln();
        await process.stdin.flush();
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
      });

      final port = int.parse(
        (await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first).trim(),
      );

      expect(await isLocalZeonProxyReady('127.0.0.1', port), isFalse);
    }, skip: !Platform.isWindows);

    test('isolated named HTTP proxy carries a request without changing Windows settings', () async {
      final proxy = await _LocalHttpProxy.start((_) => const _ProxyReply(statusCode: 200, body: '{"proxy":true}'));
      addTearDown(proxy.close);

      final response = await const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: 'http://proxy-target.invalid/through-proxy',
          headers: const {'X-Zeon-Test': 'safe'},
          timeout: const Duration(seconds: 2),
          proxyMode: WindowsProxyMode.named,
          namedProxy: '127.0.0.1:${proxy.port}',
        ),
      );

      expect(response.statusCode, 200);
      expect(jsonDecode(utf8.decode(response.body)), {'proxy': true});
      expect(proxy.requests, hasLength(1));
      expect(proxy.requests.single, contains('GET http://proxy-target.invalid/through-proxy HTTP/1.1'));
    }, skip: !Platform.isWindows);

    test('unreachable isolated named proxy fails without a direct fallback', () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();

      await expectLater(
        const WinHttpWindowsSystemTransport().send(
          WindowsSystemHttpRequest(
            method: 'GET',
            url: 'http://proxy-target.invalid/no-fallback',
            headers: const {},
            timeout: const Duration(milliseconds: 300),
            proxyMode: WindowsProxyMode.named,
            namedProxy: '127.0.0.1:$port',
          ),
        ),
        throwsA(isA<WindowsSystemNetworkException>()),
      );
    }, skip: !Platform.isWindows);

    test('407 integrated proxy authentication retries at most once', () async {
      final proxy = await _LocalHttpProxy.start(
        (_) => const _ProxyReply(statusCode: 407, headers: {'Proxy-Authenticate': 'Negotiate'}),
      );
      addTearDown(proxy.close);

      final response = await const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: 'http://proxy-target.invalid/auth',
          headers: const {'Authorization': 'Bearer must-not-be-logged'},
          timeout: const Duration(seconds: 2),
          proxyMode: WindowsProxyMode.named,
          namedProxy: '127.0.0.1:${proxy.port}',
        ),
      );

      expect(response.statusCode, 407);
      // WinHTTP may add a protocol-level Negotiate challenge round-trip, but
      // the application-level resend guard above remains exactly one.
      expect(proxy.requests.length, inInclusiveRange(1, 3));
    }, skip: !Platform.isWindows);

    test('proxy mode selection keeps production automatic and test overrides explicit', () {
      expect(winHttpAccessTypeForTesting(WindowsProxyMode.automatic), 4);
      expect(winHttpAccessTypeForTesting(WindowsProxyMode.named), 3);
      expect(winHttpAccessTypeForTesting(WindowsProxyMode.direct), 1);
    });

    test('Windows system WebSocket route uses the injected route abstraction', () async {
      final transport = _FakeWindowsWebSocketTransport();
      final client = DioHttpClient(
        timeout: const Duration(seconds: 1),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        windowsSystemWebSocketTransport: transport,
        controlPlaneMatcher: (_) => true,
      )..setVpnActive(false);

      final route = await client.openWebSocket(
        'wss://api.example.test/ws/bind',
        directOnly: true,
        headers: const {'Authorization': 'Bearer redacted'},
      );
      expect(route.routeMode, HttpRouteMode.systemNetwork.name);
      expect(route.usesLocalZeonProxy, isFalse);
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.headers['User-Agent'], 'ZEON-test');

      await route.connection.close();
      expect(transport.connection.closeCalls, 1);
    });

    test('Windows system WebSocket fails closed when no native backend exists', () async {
      final client = DioHttpClient(
        timeout: const Duration(seconds: 1),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        controlPlaneMatcher: (_) => true,
      )..setVpnActive(false);

      await expectLater(
        client.openWebSocket('wss://api.example.test/ws/bind', directOnly: true),
        throwsA(isA<WindowsSystemWebSocketUnavailableException>()),
      );
    });

    test('proxyOnly WebSocket never falls back to Windows system transport', () async {
      final transport = _FakeWindowsWebSocketTransport();
      final client =
          DioHttpClient(
              timeout: const Duration(seconds: 1),
              userAgent: 'ZEON-test',
              debug: false,
              isWindows: true,
              windowsSystemWebSocketTransport: transport,
              controlPlaneMatcher: (_) => true,
              proxyProbe: (_, _) async => false,
            )
            ..setProxyPort(12334)
            ..setVpnActive(true);

      await expectLater(
        client.openWebSocket('wss://api.example.test/ws/bind', proxyOnly: true),
        throwsA(isA<VpnProxyUnavailableException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('Windows WebSocket TLS failure remains structured', () async {
      final client = DioHttpClient(
        timeout: const Duration(seconds: 1),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        windowsSystemWebSocketTransport: const _FailingWindowsWebSocketTransport(),
        controlPlaneMatcher: (_) => true,
      )..setVpnActive(false);

      await expectLater(
        client.openWebSocket('wss://api.example.test/ws/bind', directOnly: true),
        throwsA(
          isA<WindowsSystemNetworkException>().having((error) => error.stage, 'stage', WindowsNetworkFailureStage.tls),
        ),
      );
    });

    test('DioHttpClient sends Windows system routes through the injected native transport', () async {
      final transport = _FakeWindowsTransport();
      final client = DioHttpClient(
        timeout: const Duration(seconds: 1),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        windowsSystemTransport: transport,
        controlPlaneMatcher: (_) => true,
        proxyProbe: (_, _) async => true,
      )..setVpnActive(true);

      final response = await client.get<Map<String, dynamic>>(
        'https://api.example.test/private-token',
        directOnly: true,
      );

      expect(response.data, {'ok': true});
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.url, 'https://api.example.test/private-token');
    });

    test('Windows system HTTP route fails closed without the native transport', () async {
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        controlPlaneMatcher: (_) => true,
      )..setVpnActive(false);

      await expectLater(
        client.get<void>('https://api.example.test/redacted', directOnly: true),
        throwsA(
          isA<WindowsSystemNetworkException>().having((error) => error.operation, 'operation', 'transport_unavailable'),
        ),
      );
    });

    test('structured diagnostics contain routing/native metadata but no URL or request secrets', () {
      const native = WindowsSystemNetworkException(
        operation: 'connect',
        stage: WindowsNetworkFailureStage.proxy,
        win32Code: 12180,
        hresult: 0x80072f94,
      );
      final diagnostic = windowsNetworkDiagnostic(
        routeMode: HttpRouteMode.systemNetwork,
        operation: 'bootstrap_lookup',
        error: native,
        vpnActive: false,
        localProxyReady: false,
      );

      expect(diagnostic['failure_stage'], 'proxy');
      expect(diagnostic['win32_code'], 12180);
      expect(diagnostic['trust_store'], 'windows');
      expect(diagnostic.toString(), isNot(contains('private-token')));
      expect(diagnostic.keys, isNot(contains('url')));
    });

    test('directOnly never performs VPN/local-proxy recovery', () async {
      var recoveryCalls = 0;
      final client = DioHttpClient(
        timeout: const Duration(milliseconds: 100),
        userAgent: 'ZEON-test',
        debug: false,
        isWindows: true,
        windowsSystemTransport: const _FailingWindowsTransport(),
        controlPlaneMatcher: (_) => true,
        requestVpnRecovery: () async {
          recoveryCalls++;
          return true;
        },
      );

      await expectLater(
        client.get<void>('https://api.example.test/redacted', directOnly: true),
        throwsA(isA<DioException>()),
      );
      expect(recoveryCalls, 0);
    });
  });
}

class _ProxyReply {
  const _ProxyReply({required this.statusCode, this.body = '', this.headers = const {}});

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class _LocalHttpProxy {
  _LocalHttpProxy._(this._server, this._subscription, this._reply);

  final ServerSocket _server;
  final StreamSubscription<Socket> _subscription;
  final _ProxyReply Function(String request) _reply;
  final List<String> requests = [];

  int get port => _server.port;

  static Future<_LocalHttpProxy> start(_ProxyReply Function(String request) reply) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    late _LocalHttpProxy result;
    final subscription = server.listen((socket) => result._serve(socket));
    result = _LocalHttpProxy._(server, subscription, reply);
    return result;
  }

  void _serve(Socket socket) {
    final bytes = <int>[];
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen((chunk) async {
      bytes.addAll(chunk);
      final text = latin1.decode(bytes, allowInvalid: true);
      if (!text.contains('\r\n\r\n')) return;
      await subscription.cancel();
      requests.add(text);
      final reply = _reply(text);
      final reason = reply.statusCode == 200 ? 'OK' : 'Proxy Authentication Required';
      final bodyBytes = utf8.encode(reply.body);
      final response = StringBuffer('HTTP/1.1 ${reply.statusCode} $reason\r\n')
        ..write('Content-Length: ${bodyBytes.length}\r\n')
        ..write('Connection: close\r\n');
      for (final entry in reply.headers.entries) {
        response.write('${entry.key}: ${entry.value}\r\n');
      }
      response.write('\r\n');
      socket.add(latin1.encode(response.toString()));
      socket.add(bodyBytes);
      await socket.flush();
      await socket.close();
    });
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
  }
}

class _FakeWindowsTransport implements WindowsSystemHttpTransport {
  final List<WindowsSystemHttpRequest> requests = [];

  @override
  Future<WindowsSystemHttpResponse> send(WindowsSystemHttpRequest request, {Future<Object?>? cancellation}) async {
    requests.add(request);
    return WindowsSystemHttpResponse(
      statusCode: 200,
      headers: const {
        'content-type': ['application/json'],
      },
      body: Uint8List.fromList(utf8.encode('{"ok":true}')),
      finalUrl: request.url,
    );
  }
}

class _FakeWindowsWebSocketTransport implements WindowsSystemWebSocketTransport {
  final List<WindowsSystemWebSocketRequest> requests = [];
  final _FakeAdaptiveWebSocketConnection connection = _FakeAdaptiveWebSocketConnection();

  @override
  Future<AdaptiveWebSocketConnection> connect(
    WindowsSystemWebSocketRequest request, {
    Future<Object?>? cancellation,
  }) async {
    requests.add(request);
    return connection;
  }
}

class _FakeAdaptiveWebSocketConnection implements AdaptiveWebSocketConnection {
  final StreamController<dynamic> controller = StreamController<dynamic>.broadcast();
  int closeCalls = 0;

  @override
  Stream<dynamic> get messages => controller.stream;

  @override
  Future<void> sendText(String value) async => controller.add(value);

  @override
  Future<void> sendBinary(Uint8List value) async => controller.add(value);

  @override
  void setPingInterval(Duration? interval) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalls++;
    await controller.close();
  }
}

class _FailingWindowsWebSocketTransport implements WindowsSystemWebSocketTransport {
  const _FailingWindowsWebSocketTransport();

  @override
  Future<AdaptiveWebSocketConnection> connect(WindowsSystemWebSocketRequest request, {Future<Object?>? cancellation}) {
    throw const WindowsSystemNetworkException(
      operation: 'websocket_upgrade',
      stage: WindowsNetworkFailureStage.tls,
      win32Code: 12175,
      hresult: 0x80072f8f,
    );
  }
}

class _FailingWindowsTransport implements WindowsSystemHttpTransport {
  const _FailingWindowsTransport();

  @override
  Future<WindowsSystemHttpResponse> send(WindowsSystemHttpRequest request, {Future<Object?>? cancellation}) {
    throw const WindowsSystemNetworkException(
      operation: 'connect',
      stage: WindowsNetworkFailureStage.connect,
      win32Code: 12029,
      hresult: 0x80072efd,
    );
  }
}
