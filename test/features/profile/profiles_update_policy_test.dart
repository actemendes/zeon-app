import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  group('foreground refresh timestamps', () {
    late SharedPreferences preferences;
    late ForegroundProfileRefreshTimestamps timestamps;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      preferences = await SharedPreferences.getInstance();
      timestamps = ForegroundProfileRefreshTimestamps(preferences);
    });

    test('success records both lastAttempt and lastSuccess', () async {
      final attempt = now;
      final success = now.add(const Duration(seconds: 5));

      await timestamps.recordAttempt(attempt);
      await timestamps.recordSuccess(success);

      expect(timestamps.lastAttempt, attempt);
      expect(timestamps.lastSuccess, success);
    });

    test('failure records only lastAttempt and preserves lastSuccess', () async {
      final previousSuccess = now.subtract(const Duration(hours: 1));
      await timestamps.recordSuccess(previousSuccess);

      await timestamps.recordAttempt(now);

      expect(timestamps.lastAttempt, now);
      expect(timestamps.lastSuccess, previousSuccess);
    });

    test('failed attempt has a bounded one-minute anti-spam cooldown, not a success freshness window', () {
      expect(
        shouldStartForegroundProfileRefresh(
          force: false,
          lastAttempt: now,
          lastSuccess: null,
          now: now.add(const Duration(seconds: 59)),
        ),
        isFalse,
      );
      expect(
        shouldStartForegroundProfileRefresh(
          force: false,
          lastAttempt: now,
          lastSuccess: null,
          now: now.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

    test('failure retry uses bounded backoff and never becomes a tight loop', () {
      expect(foregroundProfileRefreshRetryDelay(1), const Duration(minutes: 1));
      expect(foregroundProfileRefreshRetryDelay(2), const Duration(minutes: 2));
      expect(foregroundProfileRefreshRetryDelay(3), const Duration(minutes: 4));
      expect(foregroundProfileRefreshRetryDelay(4), const Duration(minutes: 8));
      expect(foregroundProfileRefreshRetryDelay(5), const Duration(minutes: 15));
      expect(foregroundProfileRefreshRetryDelay(100), const Duration(minutes: 15));
    });

    test('successful cycle retains the fifteen-minute freshness window', () {
      expect(
        shouldStartForegroundProfileRefresh(
          force: false,
          lastAttempt: now,
          lastSuccess: now,
          now: now.add(const Duration(minutes: 14, seconds: 59)),
        ),
        isFalse,
      );
      expect(
        shouldStartForegroundProfileRefresh(
          force: false,
          lastAttempt: now,
          lastSuccess: now,
          now: now.add(const Duration(minutes: 15)),
        ),
        isTrue,
      );
    });

    test('legacy timestamp is migrated as attempt-only', () async {
      await preferences.setString(ForegroundProfileRefreshTimestamps.legacyRunKey, now.toIso8601String());
      final legacy = ForegroundProfileRefreshTimestamps(preferences);

      expect(legacy.lastAttempt, now);
      expect(legacy.lastSuccess, isNull);

      await legacy.recordAttempt(now.add(const Duration(minutes: 1)));
      expect(preferences.containsKey(ForegroundProfileRefreshTimestamps.legacyRunKey), isFalse);
    });
  });
}
