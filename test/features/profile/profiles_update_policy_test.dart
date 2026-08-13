import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/profile/notifier/profiles_update_notifier.dart';

void main() {
  final now = DateTime.utc(2026, 8, 2, 12);

  test('enabled remote profiles refresh on the unified 15 minute cadence', () {
    expect(
      shouldRefreshProfileInUnifiedCycle(
        force: false,
        configuredUpdateInterval: const Duration(hours: 12),
        lastUpdate: now.subtract(const Duration(minutes: 15)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldRefreshProfileInUnifiedCycle(
        force: false,
        configuredUpdateInterval: const Duration(hours: 12),
        lastUpdate: now.subtract(const Duration(minutes: 14, seconds: 59)),
        now: now,
      ),
      isFalse,
    );
  });

  test('disabled profiles stay disabled unless the user forces a refresh', () {
    expect(
      shouldRefreshProfileInUnifiedCycle(
        force: false,
        configuredUpdateInterval: null,
        lastUpdate: now.subtract(const Duration(days: 1)),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldRefreshProfileInUnifiedCycle(force: true, configuredUpdateInterval: null, lastUpdate: now, now: now),
      isTrue,
    );
  });
}
