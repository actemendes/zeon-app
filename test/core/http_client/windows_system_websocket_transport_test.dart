import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/windows_network_diagnostics.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/http_client/windows_system_websocket_transport.dart';

void main() {
  final libraryPath = Platform.environment['ZEON_WINDOWS_TRANSPORT_DLL'];
  final skipNative = !Platform.isWindows || libraryPath == null || libraryPath.isEmpty;

  group('WinHTTP system WebSocket integration', () {
    late WinHttpWindowsSystemWebSocketTransport transport;

    setUp(() {
      transport = WinHttpWindowsSystemWebSocketTransport.forTesting(libraryPath!);
    });

    test('connects and exchanges text and binary messages', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));
      addTearDown(connection.close);
      final messages = StreamIterator<dynamic>(connection.messages);
      addTearDown(messages.cancel);

      await connection.sendText('hello');
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'hello');

      await connection.sendBinary(Uint8List.fromList(<int>[0, 1, 2, 255]));
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, Uint8List.fromList(<int>[0, 1, 2, 255]));
    });

    test('normal close is idempotent', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));

      await connection.close(1000, 'done');
      await connection.close(1000, 'done');
    });

    test('assembles fragmented text and binary and preserves empty messages', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.fragmentedMessages);
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));
      addTearDown(connection.close);
      final messages = StreamIterator<dynamic>(connection.messages);
      addTearDown(messages.cancel);

      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'hello');
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, Uint8List.fromList(<int>[0, 1, 2, 3]));
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, '');
    });

    test('receives a large bounded message', () async {
      final server = await _EchoWebSocketServer.start(onConnect: (socket) => socket.add('x' * 512000));
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));
      addTearDown(connection.close);

      expect(await connection.messages.first, isA<String>().having((value) => value.length, 'length', 512000));
    });

    test('handles normal remote close and dispose after close', () async {
      final server = await _EchoWebSocketServer.start(onConnect: (socket) => socket.close(1000, 'remote'), echo: false);
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));

      await connection.messages.drain<void>();
      await connection.close();
    });

    test('supports repeated and sequential sessions', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      for (var index = 0; index < 5; index++) {
        final connection = await transport.connect(_request(server.url));
        final message = connection.messages.first;
        await connection.sendText('$index');
        expect(await message, '$index');
        await connection.close();
      }
    });

    test('supports concurrent sessions without deadlock or shared-handle use', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      final connections = await Future.wait(
        List<Future<AdaptiveWebSocketConnection>>.generate(8, (_) => transport.connect(_request(server.url))),
      );

      await Future.wait(<Future<void>>[
        for (var index = 0; index < connections.length; index++)
          () async {
            final message = connections[index].messages.first;
            await connections[index].sendText('session-$index');
            expect(await message, 'session-$index');
          }(),
      ]);
      await Future.wait(connections.map((connection) => connection.close()));
    });

    test('directOnly /ws/bind uses the production Windows route abstraction', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      final client = DioHttpClient(
        timeout: const Duration(seconds: 3),
        userAgent: 'ZEON-WebSocket-Test',
        debug: false,
        isWindows: true,
        windowsSystemWebSocketTransport: transport,
        controlPlaneMatcher: (_) => true,
      )..setVpnActive(true);

      final route = await client.openWebSocket('${server.url}?bind_session_id=redacted', directOnly: true);
      expect(route.routeMode, HttpRouteMode.systemNetwork.name);
      expect(route.usesLocalZeonProxy, isFalse);
      final message = route.connection.messages.first;
      await route.connection.sendText('bind-event');
      expect(await message, 'bind-event');
      await route.connection.close();
    });

    test('classifies connection refused without direct retry', () async {
      final port = await _reserveClosedPort();
      await expectLater(
        transport.connect(_request('ws://127.0.0.1:$port/ws')),
        throwsA(
          isA<WindowsWebSocketNetworkException>().having(
            (error) => error.stage,
            'stage',
            WindowsNetworkFailureStage.connect,
          ),
        ),
      );
    });

    test('rejects invalid HTTP upgrade with the status preserved', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      await expectLater(
        transport.connect(_request('ws://127.0.0.1:${server.port}/invalid')),
        throwsA(
          isA<WindowsWebSocketNetworkException>()
              .having((error) => error.operation, 'operation', 'websocket_upgrade')
              .having((error) => error.httpUpgradeStatus, 'http status', 200),
        ),
      );
    });

    test('handles server disconnect during handshake', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.closeDuringHandshake);
      addTearDown(server.close);
      await expectLater(transport.connect(_request(server.url)), throwsA(isA<WindowsWebSocketNetworkException>()));
    });

    test('handles network disconnect while receive is pending', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.abortAfterUpgrade);
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));

      await expectLater(connection.messages, emitsError(isA<WindowsWebSocketNetworkException>()));
      await connection.close();
    });

    test('receive timeout is structured and does not deadlock', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.holdAfterUpgrade);
      addTearDown(server.close);
      final connection = await transport.connect(
        _request(server.url, receiveTimeout: const Duration(milliseconds: 250)),
      );

      await expectLater(
        connection.messages,
        emitsError(
          isA<WindowsWebSocketNetworkException>()
              .having((error) => error.operation, 'operation', 'websocket_receive')
              .having((error) => error.win32Code, 'code', 12002)
              .having((error) => error.stage, 'stage', WindowsNetworkFailureStage.websocket),
        ),
      );
    });

    test('cancels during connect without waiting for the handshake timeout', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.holdHandshake);
      addTearDown(server.close);
      final cancellation = Completer<Object?>();
      final stopwatch = Stopwatch()..start();
      var uiHeartbeats = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) => uiHeartbeats++);
      final connect = transport.connect(_request(server.url), cancellation: cancellation.future);
      Timer(const Duration(milliseconds: 100), () => cancellation.complete('test cancellation'));

      await expectLater(connect, throwsA(isA<WindowsSystemRequestCancelledException>()));
      heartbeat.cancel();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(uiHeartbeats, greaterThanOrEqualTo(3), reason: 'WinHTTP work must not block the Flutter isolate');
    });

    test('cancels while receive callback is pending', () async {
      final server = await _RawWebSocketServer.start(_RawServerBehavior.holdAfterUpgrade);
      addTearDown(server.close);
      final cancellation = Completer<Object?>();
      final connection = await transport.connect(_request(server.url), cancellation: cancellation.future);
      final error = expectLater(connection.messages, emitsError(isA<WindowsSystemRequestCancelledException>()));

      cancellation.complete('test cancellation');
      await error;
      await connection.close();
    });

    test('send and close are safe while receive is pending', () async {
      final server = await _EchoWebSocketServer.start();
      addTearDown(server.close);
      final connection = await transport.connect(_request(server.url));
      final message = connection.messages.first;

      await connection.sendText('concurrent');
      expect(await message, 'concurrent');
      await connection.close();
      await connection.close();
    });

    test('uses an isolated named proxy for WebSocket upgrade', () async {
      final proxy = await _RawWebSocketServer.start(_RawServerBehavior.remoteCloseAfterUpgrade);
      addTearDown(proxy.close);
      final connection = await transport.connect(
        _request(
          'ws://does-not-resolve.invalid/ws',
          proxyMode: WindowsProxyMode.named,
          namedProxy: '127.0.0.1:${proxy.port}',
        ),
      );

      await connection.messages.drain<void>();
      expect(proxy.requestCount, 2, reason: 'CONNECT tunnel plus WebSocket upgrade');
    });

    test('unreachable named proxy never falls back to direct', () async {
      final closedProxyPort = await _reserveClosedPort();

      await expectLater(
        transport.connect(
          _request(
            'ws://does-not-resolve.invalid/ws',
            proxyMode: WindowsProxyMode.named,
            namedProxy: '127.0.0.1:$closedProxyPort',
          ),
        ),
        throwsA(
          isA<WindowsWebSocketNetworkException>().having(
            (error) => error.stage,
            'stage',
            WindowsNetworkFailureStage.proxy,
          ),
        ),
      );
    });

    test('407 integrated auth retry is bounded and classified as proxy', () async {
      final proxy = await _RawWebSocketServer.start(_RawServerBehavior.proxyAuthRequired);
      addTearDown(proxy.close);

      await expectLater(
        transport.connect(
          _request(
            'ws://does-not-resolve.invalid/ws',
            proxyMode: WindowsProxyMode.named,
            namedProxy: '127.0.0.1:${proxy.port}',
          ),
        ),
        throwsA(
          isA<WindowsWebSocketNetworkException>()
              .having((error) => error.stage, 'stage', WindowsNetworkFailureStage.proxy)
              .having((error) => error.httpUpgradeStatus, 'status', 407)
              .having((error) => error.proxyAuthStage, 'auth stage', 'failed'),
        ),
      );
      // One application retry is allowed. Integrated Negotiate itself can use
      // another wire round-trip, but the native state machine must terminate.
      expect(proxy.requestCount, lessThanOrEqualTo(3));
    });

    test('prefers Negotiate then NTLM and classifies TLS error codes', () {
      const ntlm = 0x00000002;
      const negotiate = 0x00000010;
      expect(winHttpWebSocketPreferredProxyAuthSchemeForTesting(libraryPath!, ntlm), ntlm);
      expect(winHttpWebSocketPreferredProxyAuthSchemeForTesting(libraryPath, ntlm | negotiate), negotiate);
      for (final code in const <int>[12037, 12038, 12044, 12045, 12057, 12157, 12169, 12170, 12175, 12179, 12188]) {
        expect(
          classifyWinHttpWebSocketFailureForTesting(libraryPath, code, 3, secure: true),
          WindowsNetworkFailureStage.tls,
          reason: 'WinHTTP error $code must remain a TLS-stage failure',
        );
      }
    });

    test('rejects an untrusted TLS certificate with no bypass', () async {
      final context = SecurityContext()
        ..useCertificateChain('hiddify-core/hiddify-sing-box/replace/psiphon-quic-go/internal/testdata/cert.pem')
        ..usePrivateKey('hiddify-core/hiddify-sing-box/replace/psiphon-quic-go/internal/testdata/priv.key');
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
      final subscription = server.transform(WebSocketTransformer()).listen((socket) => socket.listen(socket.add));
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      await expectLater(
        transport.connect(_request('wss://127.0.0.1:${server.port}/ws')),
        throwsA(
          isA<WindowsWebSocketNetworkException>().having(
            (error) => error.stage,
            'stage',
            WindowsNetworkFailureStage.tls,
          ),
        ),
      );
    });

    test('diagnostics redact URL, headers and payload data', () {
      const error = WindowsWebSocketNetworkException(
        operation: 'websocket_proxy_auth',
        stage: WindowsNetworkFailureStage.proxy,
        win32Code: 12015,
        hresult: 0x80072eef,
        httpUpgradeStatus: 407,
        proxyAuthStage: 'failed',
        closeCode: null,
      );
      final diagnostic = windowsNetworkDiagnostic(
        routeMode: HttpRouteMode.systemNetwork,
        operation: 'bind_websocket',
        error: error,
        vpnActive: null,
        localProxyReady: false,
      );
      final encoded = jsonEncode(diagnostic);

      expect(diagnostic['websocket_upgrade_status'], 407);
      expect(diagnostic['proxy_auth_stage'], 'failed');
      expect(encoded, isNot(contains('bind_token_secret')));
      expect(encoded, isNot(contains('Authorization')));
      expect(encoded, isNot(contains('/ws/bind?')));
    });

    test('native and Dart sources contain no TLS validation bypass or secret logging', () async {
      final source =
          '${await File('windows/transport/zeon_windows_websocket.cpp').readAsString()}\n'
          '${await File('lib/core/http_client/windows_system_websocket_transport.dart').readAsString()}';
      expect(source, isNot(contains('SECURITY_FLAG_IGNORE')));
      expect(source, isNot(contains('WINHTTP_OPTION_SECURITY_FLAGS')));
      expect(source, isNot(contains('badCertificateCallback')));
      expect(source, isNot(contains('print(')));
    });

    test('production factory resolves the packaged native backend', () {
      expect(createWindowsSystemWebSocketTransport(), isA<WinHttpWindowsSystemWebSocketTransport>());
    });
  }, skip: skipNative ? 'Windows native transport DLL is required' : false);
}

WindowsSystemWebSocketRequest _request(
  String url, {
  Duration receiveTimeout = const Duration(seconds: 10),
  WindowsProxyMode proxyMode = WindowsProxyMode.direct,
  String? namedProxy,
}) => WindowsSystemWebSocketRequest(
  url: url,
  headers: const <String, String>{'User-Agent': 'ZEON-WebSocket-Test'},
  timeout: const Duration(seconds: 3),
  receiveTimeout: receiveTimeout,
  proxyMode: proxyMode,
  namedProxy: namedProxy,
);

class _EchoWebSocketServer {
  _EchoWebSocketServer(this._server, this._subscription);

  final HttpServer _server;
  final StreamSubscription<WebSocket> _subscription;
  int connectionCount = 0;

  String get url => 'ws://127.0.0.1:${_server.port}/ws';

  static Future<_EchoWebSocketServer> start({void Function(WebSocket socket)? onConnect, bool echo = true}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late final _EchoWebSocketServer result;
    final subscription = server.transform(WebSocketTransformer()).listen((WebSocket socket) {
      result.connectionCount++;
      onConnect?.call(socket);
      if (echo) socket.listen(socket.add);
    });
    result = _EchoWebSocketServer(server, subscription);
    return result;
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

enum _RawServerBehavior {
  fragmentedMessages,
  remoteCloseAfterUpgrade,
  abortAfterUpgrade,
  holdAfterUpgrade,
  holdHandshake,
  closeDuringHandshake,
  proxyAuthRequired,
}

class _RawWebSocketServer {
  _RawWebSocketServer(this._server, this._subscription, this.behavior);

  final ServerSocket _server;
  final StreamSubscription<Socket> _subscription;
  final _RawServerBehavior behavior;
  final List<Socket> _sockets = <Socket>[];
  int requestCount = 0;

  int get port => _server.port;
  String get url => 'ws://127.0.0.1:$port/ws';

  static Future<_RawWebSocketServer> start(_RawServerBehavior behavior) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    late final _RawWebSocketServer result;
    final subscription = server.listen((socket) {
      result._sockets.add(socket);
      if (behavior == _RawServerBehavior.closeDuringHandshake) {
        socket.destroy();
        return;
      }
      final bytes = BytesBuilder(copy: false);
      socket.listen(
        (chunk) {
          bytes.add(chunk);
          final request = ascii.decode(bytes.toBytes(), allowInvalid: true);
          if (!request.contains('\r\n\r\n')) return;
          bytes.clear();
          result.requestCount++;
          if (behavior == _RawServerBehavior.holdHandshake) return;
          if (behavior == _RawServerBehavior.proxyAuthRequired) {
            socket.add(
              ascii.encode(
                'HTTP/1.1 407 Proxy Authentication Required\r\n'
                'Proxy-Authenticate: Negotiate\r\n'
                'Content-Length: 0\r\nConnection: keep-alive\r\n\r\n',
              ),
            );
            return;
          }
          if (request.startsWith('CONNECT ')) {
            socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
            return;
          }
          final key = RegExp(
            r'^Sec-WebSocket-Key:\s*(.+?)\s*$',
            caseSensitive: false,
            multiLine: true,
          ).firstMatch(request)?.group(1);
          if (key == null) {
            socket.destroy();
            return;
          }
          final accept = base64.encode(
            _sha1(
              utf8.encode(
                '$key'
                '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
              ),
            ),
          );
          socket.add(
            ascii.encode(
              'HTTP/1.1 101 Switching Protocols\r\n'
              'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n',
            ),
          );
          switch (behavior) {
            case _RawServerBehavior.fragmentedMessages:
              socket.add(_serverFrame(opcode: 1, payload: utf8.encode('hel'), finalFrame: false));
              socket.add(_serverFrame(opcode: 0, payload: utf8.encode('lo')));
              socket.add(_serverFrame(opcode: 2, payload: <int>[0, 1], finalFrame: false));
              socket.add(_serverFrame(opcode: 0, payload: <int>[2, 3]));
              socket.add(_serverFrame(opcode: 1, payload: const <int>[]));
              socket.add(_serverFrame(opcode: 8, payload: const <int>[3, 232]));
            case _RawServerBehavior.remoteCloseAfterUpgrade:
              socket.add(_serverFrame(opcode: 8, payload: const <int>[3, 232]));
            case _RawServerBehavior.abortAfterUpgrade:
              Timer(const Duration(milliseconds: 150), socket.destroy);
            case _RawServerBehavior.holdAfterUpgrade:
            case _RawServerBehavior.holdHandshake:
            case _RawServerBehavior.closeDuringHandshake:
            case _RawServerBehavior.proxyAuthRequired:
              break;
          }
        },
        onError: (_) {},
        onDone: () => result._sockets.remove(socket),
      );
    });
    result = _RawWebSocketServer(server, subscription, behavior);
    return result;
  }

  Future<void> close() async {
    for (final socket in List<Socket>.of(_sockets)) {
      socket.destroy();
    }
    await _subscription.cancel();
    await _server.close();
  }
}

Uint8List _serverFrame({required int opcode, required List<int> payload, bool finalFrame = true}) {
  final output = BytesBuilder(copy: false)..addByte((finalFrame ? 0x80 : 0) | opcode);
  if (payload.length <= 125) {
    output.addByte(payload.length);
  } else if (payload.length <= 0xffff) {
    output
      ..addByte(126)
      ..add(<int>[payload.length >> 8, payload.length & 0xff]);
  } else {
    output
      ..addByte(127)
      ..add(<int>[0, 0, 0, 0, payload.length >> 24, payload.length >> 16, payload.length >> 8, payload.length]);
  }
  output.add(payload);
  return output.takeBytes();
}

Future<int> _reserveClosedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

List<int> _sha1(List<int> input) {
  final message = <int>[...input, 0x80];
  while (message.length % 64 != 56) {
    message.add(0);
  }
  final bitLength = input.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    message.add((bitLength >> shift) & 0xff);
  }
  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;
  var h4 = 0xc3d2e1f0;
  final words = List<int>.filled(80, 0);
  for (var offset = 0; offset < message.length; offset += 64) {
    for (var index = 0; index < 16; index++) {
      final start = offset + index * 4;
      words[index] =
          (message[start] << 24) | (message[start + 1] << 16) | (message[start + 2] << 8) | message[start + 3];
    }
    for (var index = 16; index < 80; index++) {
      words[index] = _rotateLeft(words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16], 1);
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    for (var index = 0; index < 80; index++) {
      final (function, constant) = switch (index) {
        < 20 => ((b & c) | ((~b) & d), 0x5a827999),
        < 40 => (b ^ c ^ d, 0x6ed9eba1),
        < 60 => ((b & c) | (b & d) | (c & d), 0x8f1bbcdc),
        _ => (b ^ c ^ d, 0xca62c1d6),
      };
      final temporary = (_rotateLeft(a, 5) + function + e + constant + words[index]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotateLeft(b, 30);
      b = a;
      a = temporary;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  return <int>[
    for (final word in <int>[h0, h1, h2, h3, h4])
      for (final shift in const <int>[24, 16, 8, 0]) (word >> shift) & 0xff,
  ];
}

int _rotateLeft(int value, int count) => ((value << count) | ((value & 0xffffffff) >> (32 - count))) & 0xffffffff;
