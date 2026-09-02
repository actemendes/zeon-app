import 'dart:io';

import 'package:dio/dio.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/http_client/windows_system_websocket_transport.dart';
import 'package:zeon/utils/windows_privilege_utils.dart';

Map<String, Object?> windowsNetworkDiagnostic({
  required HttpRouteMode routeMode,
  required String operation,
  required Object error,
  required bool? vpnActive,
  required bool localProxyReady,
}) {
  final nested = error is DioException ? error.error : error;
  final native = nested is WindowsSystemNetworkException ? nested : null;
  final webSocket = nested is WindowsWebSocketNetworkException ? nested : null;
  final socket = nested is SocketException ? nested.osError : null;
  final statusCode = error is DioException ? error.response?.statusCode : null;
  final stage = switch ((native, error, nested, statusCode)) {
    (final WindowsSystemNetworkException failure, _, _, _) => failure.stage.name,
    (_, _, HandshakeException(), _) => WindowsNetworkFailureStage.tls.name,
    (_, _, SocketException(), _) => WindowsNetworkFailureStage.connect.name,
    (_, _, _, 407) => WindowsNetworkFailureStage.proxy.name,
    (_, _, _, final int _) => WindowsNetworkFailureStage.http.name,
    _ => WindowsNetworkFailureStage.unknown.name,
  };

  return <String, Object?>{
    'event': 'windows_network_failure',
    'route_mode': routeMode.name,
    'operation': operation,
    'failure_stage': stage,
    'http_status': statusCode,
    'websocket_upgrade_status': webSocket?.httpUpgradeStatus,
    'proxy_auth_stage': webSocket?.proxyAuthStage,
    'websocket_close_code': webSocket?.closeCode,
    'win32_code': native?.win32Code,
    'wsa_code': socket?.errorCode,
    'hresult': native == null ? null : '0x${native.hresult.toUnsigned(32).toRadixString(16).padLeft(8, '0')}',
    'secure_failure_flags': native?.secureFailureFlags,
    'secure_failures': native?.secureFailures,
    'trust_store': routeMode == HttpRouteMode.systemNetwork ? 'windows' : 'dart_default',
    'local_proxy_ready': localProxyReady,
    'vpn_state': vpnActive == null
        ? 'unknown'
        : vpnActive
        ? 'connected'
        : 'disconnected',
    'elevated': isWindowsProcessElevated(),
  };
}
