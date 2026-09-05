import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';

/// Subscription endpoints negotiate their response format on `User-Agent`:
/// a sing-box-aware client gets native sing-box JSON (which carries
/// `tls.certificate` trust material for the self-signed FREE Trojan
/// servers), while an unrecognized client gets a legacy representation
/// without it.
///
/// `dart:io` presets `user-agent` on an auto-redirect request from
/// `HttpClient.userAgent` and then copies the previous request's headers
/// only where they are still unset, so a per-request `User-Agent` is
/// silently replaced by `Dart/x.y (dart:io)` on every redirect hop. The
/// production `/open/<id>` connection link answers with exactly such a
/// redirect to the canonical subscription URL, so losing the header there
/// silently downgraded every profile download.
void main() {
  group('DioHttpClient preserves the app User-Agent across redirects', () {
    late HttpServer server;
    late List<String?> seenUserAgents;

    setUp(() async {
      seenUserAgents = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seenUserAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
        if (request.uri.path == '/open') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://${server.address.host}:${server.port}/subscription',
          );
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.write(request.headers.value(HttpHeaders.userAgentHeader) ?? '(none)');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Future<String> downloadThroughRedirect(String userAgent) async {
      final client = DioHttpClient(
        timeout: const Duration(seconds: 10),
        userAgent: userAgent,
        debug: false,
        // This characterizes the legacy Dart HttpClient redirect path. The
        // Windows system-network path is covered by WinHTTP-specific tests.
        isWindows: false,
      );
      final tempDir = await Directory.systemTemp.createTemp('zeon_ua_test');
      final target = '${tempDir.path}${Platform.pathSeparator}payload.txt';
      try {
        await client.download('http://${server.address.host}:${server.port}/open', target, directOnly: true);
        return File(target).readAsStringSync();
      } finally {
        await tempDir.delete(recursive: true);
      }
    }

    test('redirected request still carries the ZEON User-Agent', () async {
      const zeonUserAgent = 'ZEON/1.4.1 (android) like ClashMeta v2ray sing-box';

      final body = await downloadThroughRedirect(zeonUserAgent);

      // The body is whatever User-Agent the *final* (redirected) request
      // presented to the subscription endpoint.
      expect(
        body,
        zeonUserAgent,
        reason:
            'the canonical subscription hop must still identify as ZEON, '
            'otherwise the endpoint serves a format without tls.certificate',
      );
      expect(seenUserAgents, hasLength(2));
      expect(seenUserAgents.first, zeonUserAgent);
      expect(seenUserAgents.last, zeonUserAgent);
      expect(
        seenUserAgents.last,
        isNot(startsWith('Dart/')),
        reason: 'dart:io must not substitute its default agent on redirect',
      );
    });
  });
}
