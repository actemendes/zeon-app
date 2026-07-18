import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';

void main() {
  group('buildExternalSubscriptionAccountUri', () {
    test('adds the profile fragment to a public account link', () {
      final uri = buildExternalSubscriptionAccountUri(profileUrl: 'https://zeon-vps.link/open/649669380');

      expect(uri.toString(), 'https://zeon-vps.link/open/649669380#profile');
    });

    test('preserves platform query parameters', () {
      final uri = buildExternalSubscriptionAccountUri(profileUrl: 'https://zeon-vps.link/open/123?platform=vk');

      expect(uri.toString(), 'https://zeon-vps.link/open/123?platform=vk#profile');
    });

    test('prefers the profile web page URL from subscription metadata', () {
      final uri = buildExternalSubscriptionAccountUri(
        profileUrl: 'https://zeon-vps.link/open/123',
        webPageUrl: 'https://zeon-vps.link/open/456',
      );

      expect(uri.toString(), 'https://zeon-vps.link/open/456#profile');
    });

    test('rejects a non-account subscription URL', () {
      final uri = buildExternalSubscriptionAccountUri(profileUrl: 'https://example.com/subscription/uuid');

      expect(uri, isNull);
    });
  });
}
