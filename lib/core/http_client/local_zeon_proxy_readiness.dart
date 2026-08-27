import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Verifies that the IPv4 mixed inbound is both reachable and, on Windows,
/// owned by the current ZEON process. The desktop core is loaded in-process,
/// so accepting an unrelated listener would be unsafe and misleading.
Future<bool> isLocalZeonProxyReady(String host, int port) async {
  if (host != '127.0.0.1' || port <= 0 || port > 65535) return false;
  if (Platform.isWindows && !_isCurrentProcessTcpListener(port)) return false;

  try {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 350));
    try {
      // sing-box mixed inbound supports SOCKS5. Requiring a valid negotiation
      // response rejects unrelated same-process TCP listeners as well as stale
      // ports while sending no destination or user data through the proxy.
      socket.add(const <int>[0x05, 0x01, 0x00]);
      await socket.flush();
      final response = await socket
          .expand((chunk) => chunk)
          .take(2)
          .toList()
          .timeout(const Duration(milliseconds: 350));
      return response.length == 2 && response[0] == 0x05 && response[1] == 0x00;
    } finally {
      await socket.close();
    }
  } catch (_) {
    return false;
  }
}

bool _isCurrentProcessTcpListener(int port) {
  final iphlpapi = DynamicLibrary.open('iphlpapi.dll');
  final getExtendedTcpTable = iphlpapi
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Uint32>, Int32, Uint32, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Uint32>, int, int, int, int)
      >('GetExtendedTcpTable');

  const errorInsufficientBuffer = 122;
  const afInet = 2;
  const tcpTableOwnerPidListener = 3;
  final size = calloc<Uint32>();
  try {
    var result = getExtendedTcpTable(nullptr, size, 0, afInet, tcpTableOwnerPidListener, 0);
    if (result != errorInsufficientBuffer || size.value < sizeOf<Uint32>()) return false;

    final table = calloc<Uint8>(size.value);
    try {
      result = getExtendedTcpTable(table.cast<Void>(), size, 0, afInet, tcpTableOwnerPidListener, 0);
      if (result != 0) return false;

      final words = table.cast<Uint32>();
      final count = words[0];
      const wordsPerRow = 6;
      for (var index = 0; index < count; index++) {
        final row = 1 + index * wordsPerRow;
        final networkPort = words[row + 2];
        final hostPort = ((networkPort & 0xff) << 8) | ((networkPort >> 8) & 0xff);
        final ownerPid = words[row + 5];
        if (hostPort == port && ownerPid == pid) return true;
      }
      return false;
    } finally {
      calloc.free(table);
    }
  } catch (_) {
    return false;
  } finally {
    calloc.free(size);
  }
}
