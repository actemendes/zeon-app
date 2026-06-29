import 'dart:async';

import 'package:dio/dio.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/notifications/data/notification_device_auth.dart';
import 'package:zeon/features/notifications/model/notification_entity.dart';
import 'package:zeon/features/notifications/model/notification_receipt.dart';
import 'package:zeon/utils/custom_loggers.dart';

abstract interface class NotificationRemoteDataSource {
  Future<NotificationFetchResult> fetch({
    String? cursor,
    String? eTag,
    int limit = NotificationApiDataSource.defaultLimit,
  });

  Future<void> sendReceipts(List<PendingNotificationReceipt> receipts);
}

class NotificationApiDataSource with InfraLogger implements NotificationRemoteDataSource {
  NotificationApiDataSource({
    required DioHttpClient httpClient,
    required NotificationDeviceAuth deviceAuth,
    required String appVersion,
    required String platform,
    required String locale,
    Duration timeout = const Duration(seconds: 8),
  }) : _httpClient = httpClient,
       _deviceAuth = deviceAuth,
       _appVersion = appVersion,
       _platform = platform,
       _locale = locale,
       _timeout = timeout;

  static const apiBaseUrl = MobileConnLinkImportService.apiBaseUrl;
  static const defaultLimit = 50;

  final DioHttpClient _httpClient;
  final NotificationDeviceAuth _deviceAuth;
  final String _appVersion;
  final String _platform;
  final String _locale;
  final Duration _timeout;

  @override
  Future<NotificationFetchResult> fetch({String? cursor, String? eTag, int limit = defaultLimit}) async {
    final uri = Uri.parse(apiBaseUrl)
        .resolve('/api/v1/notifications')
        .replace(
          queryParameters: {
            if (cursor != null && cursor.trim().isNotEmpty) 'cursor': cursor.trim(),
            'limit': limit.clamp(1, 100).toString(),
          },
        );

    final response = await _sendWithAuthRetry<Map<String, dynamic>>(
      (headers) => _httpClient
          .get<Map<String, dynamic>>(
            uri.toString(),
            headers: {
              ...headers,
              'Accept': 'application/json',
              if (eTag != null && eTag.trim().isNotEmpty) 'If-None-Match': eTag.trim(),
            },
            disableRetry: true,
          )
          .timeout(_timeout),
    );

    if (response.statusCode == 304) {
      return NotificationFetchResult.notModified(eTag: eTag);
    }
    if (response.statusCode != 200) {
      throw NotificationApiException('unexpected_status_${response.statusCode ?? 0}');
    }
    final page = NotificationPage.parse(response.data, eTag: _extractETag(response) ?? eTag);
    return NotificationFetchResult.page(page);
  }

  @override
  Future<void> sendReceipts(List<PendingNotificationReceipt> receipts) async {
    if (receipts.isEmpty) return;
    final uri = Uri.parse(apiBaseUrl).resolve('/api/v1/notifications/receipts').toString();
    final body = {'receipts': receipts.take(100).map((receipt) => receipt.toJson()).toList(growable: false)};
    final response = await _sendWithAuthRetry<Map<String, dynamic>>(
      (headers) => _httpClient
          .post<Map<String, dynamic>>(
            uri,
            data: body,
            headers: {...headers, 'Content-Type': 'application/json', 'Accept': 'application/json'},
            disableRetry: true,
          )
          .timeout(_timeout),
    );
    if (response.statusCode != 200) {
      throw NotificationApiException('receipts_status_${response.statusCode ?? 0}');
    }
  }

  Future<Response<T>> _sendWithAuthRetry<T>(Future<Response<T>> Function(Map<String, String> headers) send) async {
    Future<Response<T>> attempt({required bool forceRefresh}) async {
      final jwt = await _deviceAuth.resolveDeviceJwt(forceRefresh: forceRefresh);
      if (jwt.trim().isEmpty) {
        throw const NotificationApiException('device_jwt_missing');
      }
      return send({
        'Authorization': 'Bearer $jwt',
        'X-Zeon-Platform': _platform,
        'X-Zeon-App-Version': _appVersion,
        'X-Zeon-Locale': _locale,
      });
    }

    try {
      return await attempt(forceRefresh: false);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return attempt(forceRefresh: true);
      }
      rethrow;
    }
  }

  String? _extractETag(Response<dynamic> response) {
    final values = response.headers.map['etag'] ?? response.headers.map['ETag'];
    final first = values == null || values.isEmpty ? null : values.first.trim();
    return first == null || first.isEmpty ? null : first;
  }
}

sealed class NotificationFetchResult {
  const NotificationFetchResult({required this.notModified, required this.page, required this.eTag});

  factory NotificationFetchResult.page(NotificationPage page) =>
      NotificationFetchResultPage(notModified: false, page: page, eTag: page.eTag);

  factory NotificationFetchResult.notModified({String? eTag}) =>
      NotificationFetchResultPage(notModified: true, page: null, eTag: eTag);

  final bool notModified;
  final NotificationPage? page;
  final String? eTag;
}

class NotificationFetchResultPage extends NotificationFetchResult {
  const NotificationFetchResultPage({required super.notModified, required super.page, required super.eTag});
}

class NotificationApiException implements Exception {
  const NotificationApiException(this.code);

  final String code;

  @override
  String toString() => code;
}
