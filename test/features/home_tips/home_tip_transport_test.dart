import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';

void main() {
  test('binary HTTP preserves non-UTF8 image bytes on the ordinary network', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([0, 137, 255, 10]);
      await request.response.close();
    });
    final client = DioHttpClient(
      timeout: const Duration(seconds: 1),
      userAgent: 'tip-test',
      debug: false,
      isWindows: false,
    )..setVpnActive(false);
    expect(await client.getBytes('http://127.0.0.1:${server.port}/image'), [0, 137, 255, 10]);
  });

  test('Windows binary requests use native transport and never start VPN recovery', () async {
    final transport = _Transport();
    var recovered = false;
    final client = DioHttpClient(
      timeout: const Duration(seconds: 1),
      userAgent: 'tip-test',
      debug: false,
      isWindows: true,
      windowsSystemTransport: transport,
      requestVpnRecovery: () async {
        recovered = true;
        return false;
      },
    )..setVpnActive(false);
    expect(await client.getBytes('https://api.zeon-vps.online/tips/v1/assets/test.png'), [0, 137, 255]);
    transport.fail = true;
    await expectLater(client.getBytes('https://api.zeon-vps.online/tips/v1/assets/test.png'), throwsException);
    await expectLater(
      client.get<Object>('https://api.zeon-vps.online/api/v1/tips/home', allowVpnRecovery: false, disableRetry: true),
      throwsException,
    );
    expect(recovered, isFalse);
  });
}

class _Transport implements WindowsSystemHttpTransport {
  bool fail = false;
  @override
  Future<WindowsSystemHttpResponse> send(WindowsSystemHttpRequest request, {Future<Object?>? cancellation}) async {
    if (fail) throw const SocketException('offline');
    return WindowsSystemHttpResponse(
      statusCode: 200,
      headers: const {
        'content-type': ['image/png'],
      },
      body: Uint8List.fromList([0, 137, 255]),
      finalUrl: request.url,
    );
  }
}
