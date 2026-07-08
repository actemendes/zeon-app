import 'dart:async';

import 'package:dio/dio.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';
import 'package:zeon/utils/custom_loggers.dart';

class ErrorReportSender with InfraLogger {
  ErrorReportSender({required DioHttpClient httpClient, required NotificationDeviceAuth deviceAuth})
    : _httpClient = httpClient,
      _deviceAuth = deviceAuth;

  static const _apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;
  static const _endpoint = String.fromEnvironment(
    'client_error_report_endpoint',
    defaultValue: '/api/v1/client-error-reports',
  );

  final DioHttpClient _httpClient;
  final NotificationDeviceAuth _deviceAuth;

  Future<void> send(Map<String, dynamic> report) async {
    final eventId = report['event_id']?.toString() ?? '';
    try {
      final response = await _sendAttempt(report, eventId: eventId, forceRefreshToken: false);

      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw ErrorReportSendException('unexpected_status_$status');
      }
      loggy.info("client error report sent [event_id=$eventId, status=$status]");
    } on TimeoutException {
      loggy.warning("client error report deferred [event_id=$eventId, reason=timeout]");
      throw const ErrorReportSendException('timeout');
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        try {
          final response = await _sendAttempt(report, eventId: eventId, forceRefreshToken: true);
          final retryStatus = response.statusCode ?? 0;
          if (retryStatus >= 200 && retryStatus < 300) {
            loggy.info("client error report sent after auth refresh [event_id=$eventId, status=$retryStatus]");
            return;
          }
          throw ErrorReportSendException('unexpected_status_$retryStatus');
        } on DioException catch (retryError) {
          final retryStatus = retryError.response?.statusCode;
          loggy.warning(
            "client error report deferred [event_id=$eventId, reason=${retryStatus == null ? retryError.type.name : 'status_$retryStatus'}]",
          );
          throw ErrorReportSendException(retryStatus == null ? retryError.type.name : 'status_$retryStatus');
        }
      }
      loggy.warning(
        "client error report deferred [event_id=$eventId, reason=${status == null ? error.type.name : 'status_$status'}]",
      );
      throw ErrorReportSendException(status == null ? error.type.name : 'status_$status');
    }
  }

  Future<Response<Map<String, dynamic>>> _sendAttempt(
    Map<String, dynamic> report, {
    required String eventId,
    required bool forceRefreshToken,
  }) async {
    final jwt = await _deviceAuth.resolveDeviceJwt(forceRefresh: forceRefreshToken);
    if (jwt.trim().isEmpty) {
      throw const ErrorReportSendException('device_jwt_missing');
    }

    return _httpClient
        .post<Map<String, dynamic>>(
          _reportUri().toString(),
          data: report,
          headers: {
            'Authorization': 'Bearer $jwt',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Idempotency-Key': eventId,
            'X-Zeon-Report-Schema': '1',
          },
          directOnly: true,
          disableRetry: true,
        )
        .timeout(const Duration(seconds: 10));
  }

  Uri _reportUri() {
    final endpoint = Uri.parse(_endpoint);
    if (endpoint.hasScheme) return endpoint;
    final normalizedPath = _endpoint.startsWith('/') ? _endpoint : '/$_endpoint';
    return Uri.parse(_apiBaseUrl).resolve(normalizedPath);
  }
}

class ErrorReportSendException implements Exception {
  const ErrorReportSendException(this.code);

  final String code;

  @override
  String toString() => code;
}
