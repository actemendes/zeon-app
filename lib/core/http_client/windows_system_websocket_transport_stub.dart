import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';

WindowsSystemWebSocketTransport? createWindowsSystemWebSocketTransport() => null;

class WindowsWebSocketNetworkException extends WindowsSystemNetworkException {
  const WindowsWebSocketNetworkException({
    required super.operation,
    required super.stage,
    required super.win32Code,
    required super.hresult,
    required this.httpUpgradeStatus,
    required this.proxyAuthStage,
    required this.closeCode,
  });

  final int? httpUpgradeStatus;
  final String? proxyAuthStage;
  final int? closeCode;
}
