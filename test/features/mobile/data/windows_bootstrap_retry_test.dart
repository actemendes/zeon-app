import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';

void main() {
  test('Windows bootstrap retries transport failures', () {
    final request = RequestOptions(path: 'https://redacted.invalid');
    expect(
      isWindowsBootstrapTransportFailure(DioException(requestOptions: request, type: DioExceptionType.connectionError)),
      isTrue,
    );
    expect(
      isWindowsBootstrapTransportFailure(const MobileConnLinkImportException('import_failed', transportFailure: true)),
      isTrue,
    );
  });

  test('Windows bootstrap does not retry valid HTTP/server failures', () {
    final request = RequestOptions(path: 'https://redacted.invalid');
    expect(
      isWindowsBootstrapTransportFailure(
        DioException.badResponse(
          statusCode: 403,
          requestOptions: request,
          response: Response<void>(requestOptions: request, statusCode: 403),
        ),
      ),
      isFalse,
    );
    expect(isWindowsBootstrapTransportFailure(const MobileConnLinkImportException('validation_error')), isFalse);
  });

  test('UI-ready retry is consumed at most once after a transport failure', () {
    final policy = WindowsBootstrapUiRetryPolicy();
    final request = RequestOptions(path: 'https://redacted.invalid');
    policy.recordFailure(DioException(requestOptions: request, type: DioExceptionType.connectionError));

    expect(policy.takeRetry(), isTrue);
    expect(policy.consumed, isTrue);
    policy.recordFailure(DioException(requestOptions: request, type: DioExceptionType.connectionError));
    expect(policy.takeRetry(), isFalse);
  });

  test('UI-ready retry ignores HTTP, server, and validation failures', () {
    final policy = WindowsBootstrapUiRetryPolicy();
    final request = RequestOptions(path: 'https://redacted.invalid');
    policy.recordFailure(
      DioException.badResponse(
        statusCode: 503,
        requestOptions: request,
        response: Response<void>(requestOptions: request, statusCode: 503),
      ),
    );
    expect(policy.takeRetry(), isFalse);
    policy.recordFailure(const MobileConnLinkImportException('validation_error'));
    expect(policy.takeRetry(), isFalse);
  });

  test('saved conn_link transport failure alone permits Windows lookup/create fallback', () {
    final transport = const MobileConnLinkImportException('transport', transportFailure: true);
    final server = const MobileConnLinkImportException('http_or_validation');

    expect(shouldContinueAfterSavedConnLinkFailure(isWindows: true, error: transport), isTrue);
    expect(shouldContinueAfterSavedConnLinkFailure(isWindows: false, error: transport), isFalse);
    expect(shouldContinueAfterSavedConnLinkFailure(isWindows: true, error: server), isFalse);
  });
}
