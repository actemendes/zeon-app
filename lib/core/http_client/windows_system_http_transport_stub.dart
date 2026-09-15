import 'dart:typed_data';

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

WindowsSystemHttpTransport? createWindowsSystemHttpTransport() => null;

class WindowsSystemRequestCancelledException implements Exception {
  const WindowsSystemRequestCancelledException(this.reason);

  final Object? reason;
}

enum WindowsNetworkFailureStage { dns, connect, tls, proxy, http, websocket, unknown }

class WindowsSystemNetworkException implements Exception {
  const WindowsSystemNetworkException({
    required this.operation,
    required this.stage,
    required this.win32Code,
    required this.hresult,
    this.secureFailureFlags,
  });

  final String operation;
  final WindowsNetworkFailureStage stage;
  final int win32Code;
  final int hresult;
  final int? secureFailureFlags;

  List<String> get secureFailures => decodeWinHttpSecureFailureFlags(secureFailureFlags ?? 0);

  @override
  String toString() {
    return 'WindowsSystemNetworkException(operation=$operation, stage=${stage.name}, '
        'win32Code=$win32Code, hresult=$hresult)';
  }
}

List<String> decodeWinHttpSecureFailureFlags(int flags) {
  const names = <int, String>{
    0x01: 'revocationCheckFailed',
    0x02: 'invalidCertificate',
    0x04: 'revokedCertificate',
    0x08: 'untrustedCertificateAuthority',
    0x10: 'nameMismatch',
    0x20: 'dateInvalid',
    0x40: 'channelError',
  };
  final result = <String>[];
  var known = 0;
  for (final entry in names.entries) {
    if (flags & entry.key != 0) {
      known |= entry.key;
      result.add(entry.value);
    }
  }
  final unknown = flags & ~known;
  if (unknown != 0) result.add('unknown(0x${unknown.toRadixString(16)})');
  return result;
}
