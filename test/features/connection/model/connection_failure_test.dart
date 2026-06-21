import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';

void main() {
  group('isTunInterfacePermissionDenied', () {
    test('matches the transient TUN configuration failure', () {
      const error = ConnectionFailure.unexpected(
        'manager start inbound/tun[tun-in]: configure tun interface: permission denied',
      );

      expect(isTunInterfacePermissionDenied(error), isTrue);
    });

    test('matches the failure when it contains diagnostic wrappers', () {
      const error = '''
Caused by:
manager start inbound/tun[tun-in]: configure tun interface: permission denied
Error:
manager start inbound/tun[tun-in]: configure tun interface: permission denied
''';

      expect(isTunInterfacePermissionDenied(error), isTrue);
    });

    test('does not match unrelated permission failures', () {
      expect(isTunInterfacePermissionDenied('VPN permission denied by user'), isFalse);
      expect(isTunInterfacePermissionDenied(const ConnectionFailure.missingPrivilege()), isFalse);
    });
  });
}
