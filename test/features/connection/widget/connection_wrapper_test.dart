import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/widget/connection_wrapper.dart';

void main() {
  group('hasStableVpnTransport', () {
    test('requires a stable Connected state', () {
      expect(hasStableVpnTransport(const Connected()), isTrue);
    });

    test('does not require a proxy while the VPN is unavailable or switching', () {
      for (final status in <ConnectionStatus>[const Disconnected(), const Connecting(), const Disconnecting()]) {
        expect(hasStableVpnTransport(status), isFalse, reason: status.runtimeType.toString());
      }
    });
  });
}
