import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';

void main() {
  group('shouldReconnectForActiveProfileChange', () {
    test('reconnects when a release-speed transition has no previous provider value', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: true,
          connectedProfileId: 'anonymous',
          nextProfileId: 'device-profile',
        ),
        isTrue,
      );
    });

    test('does not reconnect for the profile already running in the core', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: true,
          connectedProfileId: 'device-profile',
          nextProfileId: 'device-profile',
        ),
        isFalse,
      );
    });

    test('does not reconnect while disconnected', () {
      expect(
        shouldReconnectForActiveProfileChange(
          connected: false,
          connectedProfileId: 'anonymous',
          nextProfileId: 'device-profile',
        ),
        isFalse,
      );
    });
  });
}
