// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/core/model/environment.dart';
import 'package:zeon/features/app_update/data/app_update_repository.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    test('fetches ZEON catalog and selects the $platform installer', () async {
      debugDefaultTargetPlatformOverride = platform;
      final client = _CatalogHttpClient();
      final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
      expect(client.requestedUrls, ['https://api.zeon-vps.online/app/releases']);
      result.match((failure) => fail('$failure'), (release) {
        expect(release.version, '1.5.1');
        expect(release.buildNumber, isEmpty);
        final extension = platform == TargetPlatform.android ? 'apk' : 'exe';
        expect(release.url, 'https://api.zeon-vps.online/download/releases/ZEON-1.5.1.$extension');
      });
    });
  }

  test('store releases make no catalog request', () async {
    for (final release in [Release.googlePlay, Release.appStore]) {
      final client = _CatalogHttpClient();
      final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion(release: release).run();
      expect(result.isLeft(), isTrue);
      expect(client.requestedUrls, isEmpty);
    }
  });

  test('accepts a JSON string response from the Windows transport', () async {
    final result = await AppUpdateRepositoryImpl(httpClient: _CatalogHttpClient(asText: true)).getLatestVersion().run();
    expect(result.isRight(), isTrue);
  });

  test('reports an unavailable catalog without falling back to GitHub', () async {
    final client = _CatalogHttpClient(status: 503);
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(result.isLeft(), isTrue);
    expect(client.requestedUrls, ['https://api.zeon-vps.online/app/releases']);
  });
}

class _CatalogHttpClient extends DioHttpClient {
  _CatalogHttpClient({this.asText = false, this.status = 200})
    : super(timeout: const Duration(seconds: 5), userAgent: 'ZEON-test', debug: false, isWindows: false);

  final bool asText;
  final int status;
  final requestedUrls = <String>[];

  @override
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    Map<String, String>? headers,
    bool proxyOnly = false,
    bool directOnly = false,
    bool disableRetry = false,
    String? operation,
    bool allowVpnRecovery = true,
  }) async {
    requestedUrls.add(url);
    final catalog = [
      {
        'tag_name': 'v1.5.1',
        'prerelease': false,
        'published_at': '2026-09-17T00:00:00Z',
        'html_url': 'https://zeon-vps.net',
        'assets': [
          {
            'name': 'zeon-android-universal.apk',
            'browser_download_url': 'https://api.zeon-vps.online/download/releases/ZEON-1.5.1.apk',
          },
          {
            'name': 'zeon-windows-setup-x64.exe',
            'browser_download_url': 'https://api.zeon-vps.online/download/releases/ZEON-1.5.1.exe',
          },
        ],
      },
    ];
    return Response<T>(
      data: (asText ? jsonEncode(catalog) : catalog) as T,
      statusCode: status,
      requestOptions: RequestOptions(path: url),
    );
  }
}
