import 'dart:convert';
import 'dart:io';

import 'package:zeon/core/http_client/windows_system_http_transport.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stderr.writeln('This diagnostic probe requires Windows.');
    exitCode = 2;
    return;
  }

  final targets = args.isEmpty
      ? const <String>['https://api.zeon-vps.online/health', 'https://130.49.151.173/health']
      : args;

  for (final target in targets) {
    final uri = Uri.tryParse(target);
    if (uri == null || uri.host.isEmpty || uri.scheme != 'https') {
      stdout.writeln(jsonEncode(<String, Object?>{'event': 'invalid_target'}));
      continue;
    }

    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    List<InternetAddress> addresses = const <InternetAddress>[];
    try {
      addresses = await InternetAddress.lookup(uri.host);
    } catch (_) {
      // The WinHTTP result below remains authoritative for the request path.
    }

    try {
      final response = await const WinHttpWindowsSystemTransport().send(
        WindowsSystemHttpRequest(
          method: 'GET',
          url: target,
          headers: const <String, String>{'User-Agent': 'ZEON-bootstrap-diagnostic'},
          timeout: const Duration(seconds: 10),
          proxyMode: WindowsProxyMode.direct,
        ),
      );
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'event': 'windows_bootstrap_tls_probe',
          'timestamp_utc': startedAt.toIso8601String(),
          'host': uri.host,
          'port': uri.port,
          'proxy_mode': WindowsProxyMode.direct.name,
          'dns_a': addresses
              .where((address) => address.type == InternetAddressType.IPv4)
              .map((e) => e.address)
              .toList(),
          'dns_aaaa': addresses
              .where((address) => address.type == InternetAddressType.IPv6)
              .map((e) => e.address)
              .toList(),
          'status': response.statusCode,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        }),
      );
    } on WindowsSystemNetworkException catch (error) {
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'event': 'windows_bootstrap_tls_probe',
          'timestamp_utc': startedAt.toIso8601String(),
          'host': uri.host,
          'port': uri.port,
          'proxy_mode': WindowsProxyMode.direct.name,
          'dns_a': addresses
              .where((address) => address.type == InternetAddressType.IPv4)
              .map((e) => e.address)
              .toList(),
          'dns_aaaa': addresses
              .where((address) => address.type == InternetAddressType.IPv6)
              .map((e) => e.address)
              .toList(),
          'operation': error.operation,
          'stage': error.stage.name,
          'win32': error.win32Code,
          'hresult': '0x${error.hresult.toUnsigned(32).toRadixString(16).padLeft(8, '0')}',
          'secure_failure_flags': error.secureFailureFlags,
          'secure_failures': error.secureFailures,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
        }),
      );
    }
  }
}
