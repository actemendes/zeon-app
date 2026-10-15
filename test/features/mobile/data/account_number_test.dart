import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/http_client/dio_http_client.dart';
import 'package:zeon/features/mobile/data/account_number.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/profile/data/profile_data_source.dart';
import 'package:zeon/features/profile/data/profile_repository.dart';

// Normalization must not access transport, storage or native profile validation.
// Fake throws if any of these dependencies is used.
class _UnusedHttpClient extends Fake implements DioHttpClient {}

class _UnusedProfileRepository extends Fake implements ProfileRepository {}

class _UnusedProfileDataSource extends Fake implements ProfileDataSource {}

class _UnusedPreferences extends Fake implements SharedPreferences {}

void main() {
  group('isValidAccountNumber', () {
    test('accepts short, ordinary and largest exactly representable account IDs', () {
      for (final value in ['1', '12', '123', '1234', '12345678', '9007199254740991']) {
        expect(isValidAccountNumber(value), isTrue, reason: value);
      }
    });

    test('rejects zero and leading zeros instead of changing account identity', () {
      for (final value in ['', '0', '00', '01', '0123', '00001234']) {
        expect(isValidAccountNumber(value), isFalse, reason: value);
      }
    });

    test('rejects unsafe integer precision and excessive length', () {
      for (final value in ['9007199254740992', '9999999999999999', '10000000000000000']) {
        expect(isValidAccountNumber(value), isFalse, reason: value);
      }
    });

    test('does not trim, remove letters or coerce numeric expressions', () {
      for (final value in [
        ' 1234',
        '1234 ',
        '1234\n',
        '\n1234',
        '12 34',
        '12\n34',
        '+1234',
        '-1234',
        '12.34',
        '1e4',
        '0x1234',
        'abc1234',
        '1234abc',
        '١٢٣٤',
        '１２３４',
        '00000000-0000-4000-8000-000000000001',
        'https://example.invalid/open/1234',
      ]) {
        expect(isValidAccountNumber(value), isFalse, reason: value);
      }
    });
  });

  group('account import normalization', () {
    late MobileConnLinkImportService service;

    setUp(() {
      service = MobileConnLinkImportService(
        httpClient: _UnusedHttpClient(),
        profileRepository: _UnusedProfileRepository(),
        profileDataSource: _UnusedProfileDataSource(),
        preferences: _UnusedPreferences(),
      );
    });

    void expectOpenAccount(String input, String expectedId) {
      final result = service.normalizeConnectionLink(input);
      expect(
        result.primaryConnLink,
        Uri.parse(MobileConnLinkImportService.apiBaseUrl).resolve('/open/$expectedId').toString(),
      );
      // The import/rebind pipeline needs the complete ID, not just a valid URL.
      expect(result.openId, expectedId);
    }

    test('bare one to three digit account IDs retain identity for rebind', () {
      for (final id in ['1', '12', '123']) {
        expectOpenAccount(id, id);
      }
    });

    test('public and API open links recognize one to three digit IDs', () {
      for (final id in ['1', '12', '123']) {
        expectOpenAccount('${MobileConnLinkImportService.publicOpenBaseUrl}/open/$id?platform=st', id);
        expectOpenAccount('${MobileConnLinkImportService.apiBaseUrl}/open/$id', id);
      }
    });

    test('ordinary and boundary account IDs retain existing normalization', () {
      for (final id in ['1234', '12345678', '9007199254740991']) {
        expectOpenAccount(id, id);
        expectOpenAccount('${MobileConnLinkImportService.publicOpenBaseUrl}/open/$id', id);
      }
    });

    test('existing alphanumeric and UUID open tokens are not rewritten as numbers', () {
      for (final token in ['abc1234', 'legacy_code-1', '00000000-0000-4000-8000-000000000001']) {
        expectOpenAccount(token, token);
        expectOpenAccount('${MobileConnLinkImportService.publicOpenBaseUrl}/open/$token', token);
        expect(isValidAccountNumber(token), isFalse);
      }
    });

    test('full UUID subscription URLs remain full-link imports', () {
      const url = 'https://api.zeon-vps.online/subscription/00000000-0000-4000-8000-000000000001';
      final result = service.normalizeConnectionLink(url);
      expect(result.primaryConnLink, url);
      expect(result.openId, isNull);
    });

    test('short invalid numeric forms do not become open account IDs', () {
      for (final value in ['0', '01', '001', 'a12', '+12', '-12']) {
        expect(service.normalizeConnectionLink(value).openId, isNull, reason: value);
        expect(isValidAccountNumber(value), isFalse, reason: value);
      }
    });

    test('TV rejects leading zeros while legacy full-link handling is preserved', () {
      const token = '001234';
      expect(isValidAccountNumber(token), isFalse);
      expectOpenAccount('${MobileConnLinkImportService.publicOpenBaseUrl}/open/$token', token);
    });
  });
}
