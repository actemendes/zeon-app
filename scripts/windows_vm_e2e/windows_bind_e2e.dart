import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zeon/core/http_client/adaptive_websocket.dart';
import 'package:zeon/core/http_client/windows_system_http_transport.dart';
import 'package:zeon/core/http_client/windows_system_websocket_transport.dart';

/// Guest-only production transport harness for the fresh-install Windows VM.
///
/// Required environment variables:
///   ZEON_E2E_API_BASE_URL
///   ZEON_E2E_API_KEY
///   ZEON_WINDOWS_TRANSPORT_DLL
///
/// The harness deliberately never prints URLs, credentials, session IDs,
/// bind codes, response bodies, WebSocket payloads, or device identifiers.
Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('result=unsupported_platform');
    exitCode = 2;
    return;
  }

  final baseUrl = (Platform.environment['ZEON_E2E_API_BASE_URL'] ?? '').trim();
  final apiKey = (Platform.environment['ZEON_E2E_API_KEY'] ?? '').trim();
  final transportDll = (Platform.environment['ZEON_WINDOWS_TRANSPORT_DLL'] ?? '').trim();
  final idleSeconds = _positiveIntArgument(arguments, '--idle-seconds', fallback: 180);
  if (baseUrl.isEmpty || apiKey.isEmpty || transportDll.isEmpty) {
    stderr.writeln('result=missing_configuration');
    exitCode = 2;
    return;
  }

  final baseUri = Uri.tryParse(baseUrl);
  if (baseUri == null || baseUri.host.isEmpty || (baseUri.scheme != 'https' && baseUri.scheme != 'http')) {
    stderr.writeln('result=invalid_configuration');
    exitCode = 2;
    return;
  }

  const http = WinHttpWindowsSystemTransport();
  final webSocket = createWindowsSystemWebSocketTransport();
  if (webSocket == null) {
    stderr.writeln('result=native_transport_unavailable');
    exitCode = 2;
    return;
  }
  AdaptiveWebSocketConnection? connection;
  StreamSubscription<dynamic>? subscription;
  String? ownerToken;
  String? sessionId;
  var remoteClosed = false;
  var receivedEvent = false;

  try {
    final owner = await _createDevice(http, baseUri, apiKey);
    final target = await _createDevice(http, baseUri, apiKey);
    ownerToken = owner.token;

    final create = await _requestJson(
      http,
      baseUri.resolve('/bind/session/create'),
      method: 'POST',
      token: owner.token,
      body: <String, Object?>{
        'device_id': owner.deviceId,
        'client_meta': const <String, Object?>{'platform': 'windows'},
      },
    );
    sessionId = _requiredString(create, 'bind_session_id');
    final bindCode = _requiredString(create, 'bind_code');

    final wsUri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/bind',
      queryParameters: <String, String>{'bind_session_id': sessionId},
    );
    connection = await webSocket.connect(
      WindowsSystemWebSocketRequest(
        url: wsUri.toString(),
        headers: <String, String>{'Authorization': 'Bearer ${owner.token}'},
        timeout: const Duration(seconds: 30),
        receiveTimeout: Duration(seconds: idleSeconds + 120),
      ),
    );
    stdout.writeln('websocket_connected=true');

    final firstEvent = Completer<void>();
    subscription = connection.messages.listen(
      (dynamic raw) {
        if (_containsNamedEvent(raw)) {
          receivedEvent = true;
          if (!firstEvent.isCompleted) firstEvent.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!firstEvent.isCompleted) firstEvent.completeError(error, stackTrace);
      },
      onDone: () {
        remoteClosed = true;
        if (!firstEvent.isCompleted) {
          firstEvent.completeError(StateError('remote_close'));
        }
      },
      cancelOnError: false,
    );

    await Future<void>.delayed(Duration(seconds: idleSeconds));
    stdout.writeln('idle_seconds=$idleSeconds');
    stdout.writeln('idle_connection_open=${!remoteClosed}');
    if (remoteClosed) throw StateError('idle_remote_close');

    await _requestJson(
      http,
      baseUri.resolve('/bind/session/confirm'),
      method: 'POST',
      token: target.token,
      body: <String, Object?>{
        // MobileBindService rotates the target device ID when the token's
        // original device is already bound. Use that resulting state directly
        // so the VM harness follows the same production confirm contract.
        'device_id': _randomDeviceId(),
        'bind_code': bindCode,
        'client_meta': const <String, Object?>{'platform': 'windows'},
      },
    );

    try {
      await firstEvent.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      // Status is checked independently below. A missing event remains a
      // failing WebSocket result even if the HTTP state transitioned.
    }

    final status = await _requestJson(
      http,
      baseUri.resolve('/bind/session/status').replace(queryParameters: <String, String>{'bind_session_id': sessionId}),
      method: 'GET',
      token: owner.token,
    );
    final statusValue = (status['status']?.toString() ?? '').trim().toLowerCase();
    final statusConfirmed = statusValue == 'confirmed' || statusValue == 'completed' || statusValue == 'bound';
    stdout.writeln('event_received=$receivedEvent');
    stdout.writeln('status_confirmed=$statusConfirmed');
    if (!receivedEvent || !statusConfirmed) {
      throw StateError('bind_flow_incomplete');
    }

    await connection.close(1000, 'e2e complete');
    stdout.writeln('normal_close=true');
    stdout.writeln('result=pass');
  } catch (error) {
    _writeSafeFailure(error);
    exitCode = 1;
  } finally {
    await subscription?.cancel();
    if (connection != null) {
      try {
        await connection.close(1000, 'e2e cleanup');
      } catch (_) {
        // Best-effort cleanup; the safe primary failure is already recorded.
      }
    }
    if (ownerToken != null && sessionId != null) {
      try {
        await _requestJson(
          http,
          baseUri.resolve('/bind/session/cancel'),
          method: 'POST',
          token: ownerToken,
          body: <String, Object?>{'bind_session_id': sessionId},
          acceptFailure: true,
        );
      } catch (_) {
        // The server may already have finalized the confirmed session.
      }
    }
  }
}

Future<_DeviceAuth> _createDevice(WindowsSystemHttpTransport http, Uri baseUri, String apiKey) async {
  final deviceId = _randomDeviceId();
  final create = await _requestJson(
    http,
    baseUri.resolve('/api/v1/users/create'),
    method: 'POST',
    apiKey: apiKey,
    body: <String, Object?>{
      'device_id': deviceId,
      'platform': 'windows',
      'subscription': const <String, Object?>{'create_if_missing': true},
    },
  );
  final user = create['user'];
  if (user is! Map<String, dynamic>) throw StateError('invalid_user_response');
  final userId = int.tryParse(user['user_id']?.toString() ?? '');
  if (userId == null || userId <= 0) throw StateError('invalid_user_response');

  final tokenPayload = await _requestJson(
    http,
    baseUri.resolve('/api/v1/bind/token'),
    method: 'POST',
    apiKey: apiKey,
    body: <String, Object?>{'device_id': deviceId, 'user_id': userId, 'sub': 'mobile-client'},
  );
  return _DeviceAuth(deviceId, _requiredString(tokenPayload, 'token'));
}

Future<Map<String, dynamic>> _requestJson(
  WindowsSystemHttpTransport http,
  Uri uri, {
  required String method,
  String? apiKey,
  String? token,
  Map<String, Object?>? body,
  bool acceptFailure = false,
}) async {
  final headers = <String, String>{'Accept': 'application/json'};
  if (body != null) headers['Content-Type'] = 'application/json';
  if (apiKey != null) headers['x-api-key'] = apiKey;
  if (token != null) headers['Authorization'] = 'Bearer $token';
  final response = await http.send(
    WindowsSystemHttpRequest(
      method: method,
      url: uri.toString(),
      headers: headers,
      body: body == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(body))),
      timeout: const Duration(seconds: 30),
    ),
  );
  if (acceptFailure && (response.statusCode < 200 || response.statusCode >= 300)) {
    return const <String, dynamic>{};
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw _SafeHttpFailure(response.statusCode);
  }
  final decoded = jsonDecode(utf8.decode(response.body));
  if (decoded is! Map<String, dynamic>) throw StateError('invalid_json_response');
  if (decoded['ok'] == false) throw StateError('server_rejected_request');
  final data = decoded['data'];
  return data is Map<String, dynamic> ? data : decoded;
}

bool _containsNamedEvent(dynamic raw) {
  try {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is Uint8List) {
      text = utf8.decode(raw);
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      return false;
    }
    final value = jsonDecode(text);
    return value is Map<String, dynamic> && (value['event']?.toString().trim().isNotEmpty ?? false);
  } catch (_) {
    return false;
  }
}

String _requiredString(Map<String, dynamic> value, String key) {
  final result = (value[key]?.toString() ?? '').trim();
  if (result.isEmpty) throw StateError('missing_required_response_field');
  return result;
}

String _randomDeviceId() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  return bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
}

int _positiveIntArgument(List<String> arguments, String name, {required int fallback}) {
  final prefix = '$name=';
  final raw = arguments.where((String value) => value.startsWith(prefix)).firstOrNull;
  final parsed = raw == null ? null : int.tryParse(raw.substring(prefix.length));
  return parsed != null && parsed > 0 && parsed <= 1800 ? parsed : fallback;
}

void _writeSafeFailure(Object error) {
  if (error is WindowsWebSocketNetworkException) {
    stderr.writeln('failure_type=websocket_network');
    stderr.writeln('operation=${error.operation}');
    stderr.writeln('failure_stage=${error.stage.name}');
    stderr.writeln('win32_code=${error.win32Code}');
    stderr.writeln('http_upgrade_status=${error.httpUpgradeStatus ?? 0}');
    stderr.writeln('proxy_auth_stage=${error.proxyAuthStage ?? 'none'}');
    stderr.writeln('close_code=${error.closeCode ?? 0}');
  } else if (error is WindowsSystemNetworkException) {
    stderr.writeln('failure_type=http_network');
    stderr.writeln('operation=${error.operation}');
    stderr.writeln('failure_stage=${error.stage.name}');
    stderr.writeln('win32_code=${error.win32Code}');
  } else if (error is _SafeHttpFailure) {
    stderr.writeln('failure_type=http_status');
    stderr.writeln('http_status=${error.statusCode}');
  } else {
    stderr.writeln('failure_type=${error.runtimeType}');
  }
  stderr.writeln('result=fail');
}

final class _DeviceAuth {
  const _DeviceAuth(this.deviceId, this.token);

  final String deviceId;
  final String token;
}

final class _SafeHttpFailure implements Exception {
  const _SafeHttpFailure(this.statusCode);

  final int statusCode;
}

extension on Iterable<String> {
  String? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
