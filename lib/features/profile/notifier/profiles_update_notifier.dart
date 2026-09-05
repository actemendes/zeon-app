import 'dart:async';

import 'package:meta/meta.dart';
import 'package:neat_periodic_task/neat_periodic_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/notification/in_app_notification_controller.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/data/profile_name_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/route_rules/data/managed_rule_set_sync.dart';
import 'package:zeon/utils/custom_loggers.dart';

part 'profiles_update_notifier.g.dart';

typedef ProfileUpdateStatus = ({String name, bool success});

const unifiedProfileAndRuleSetRefreshInterval = Duration(minutes: 15);
const foregroundProfileRefreshFailureRetryInterval = Duration(minutes: 1);

@visibleForTesting
bool shouldStartForegroundProfileRefresh({
  required bool force,
  required DateTime? lastAttempt,
  required DateTime? lastSuccess,
  required DateTime now,
}) {
  if (force) return true;
  if (lastSuccess != null && now.isBefore(lastSuccess.add(unifiedProfileAndRuleSetRefreshInterval))) {
    return false;
  }
  if (lastAttempt != null && now.isBefore(lastAttempt.add(foregroundProfileRefreshFailureRetryInterval))) {
    return false;
  }
  return true;
}

@visibleForTesting
Duration foregroundProfileRefreshRetryDelay(int consecutiveFailures) {
  const delays = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 4),
    Duration(minutes: 8),
    unifiedProfileAndRuleSetRefreshInterval,
  ];
  final index = (consecutiveFailures - 1).clamp(0, delays.length - 1);
  return delays[index];
}

@visibleForTesting
class ForegroundProfileRefreshTimestamps {
  ForegroundProfileRefreshTimestamps(this._preferences);

  static const lastAttemptKey = "profiles_update_last_attempt";
  static const lastSuccessKey = "profiles_update_last_success";
  static const legacyRunKey = "profiles_update_check";

  final SharedPreferences _preferences;

  DateTime? get lastAttempt =>
      _read(lastAttemptKey) ?? _read(legacyRunKey); // Legacy value is attempt-only: it may represent a failed cycle.

  DateTime? get lastSuccess => _read(lastSuccessKey);

  Future<void> recordAttempt(DateTime timestamp) async {
    await _preferences.setString(lastAttemptKey, timestamp.toIso8601String());
    await _preferences.remove(legacyRunKey);
  }

  Future<void> recordSuccess(DateTime timestamp) => _preferences.setString(lastSuccessKey, timestamp.toIso8601String());

  DateTime? _read(String key) => DateTime.tryParse(_preferences.getString(key) ?? "");
}

@visibleForTesting
bool shouldRefreshProfileInUnifiedCycle({
  required bool force,
  required Duration? configuredUpdateInterval,
  required DateTime lastUpdate,
  required DateTime now,
}) =>
    force || configuredUpdateInterval != null && unifiedProfileAndRuleSetRefreshInterval <= now.difference(lastUpdate);

@Riverpod(keepAlive: true)
class ForegroundProfilesUpdateNotifier extends _$ForegroundProfilesUpdateNotifier with AppLogger {
  static const interval = unifiedProfileAndRuleSetRefreshInterval;

  @override
  Stream<ProfileUpdateStatus?> build() {
    var cycleCount = 0;
    _scheduler = NeatPeriodicTaskScheduler(
      name: 'profiles update worker',
      interval: interval,
      timeout: const Duration(minutes: 5),
      task: () async {
        loggy.debug("cycle [${cycleCount++}]");
        await updateProfiles();
      },
    );

    ref.onDispose(() async {
      _retryTimer?.cancel();
      _retryTimer = null;
      await _scheduler?.stop();
      _scheduler = null;
    });

    if (ref.watch(Preferences.introCompleted)) {
      loggy.debug("intro done, starting");
      _scheduler?.start();
    } else {
      loggy.debug("intro in process, skipping");
    }
    return const Stream.empty();
  }

  NeatPeriodicTaskScheduler? _scheduler;
  Timer? _retryTimer;
  int _consecutiveFailedCycles = 0;
  bool _forceNextRun = false;

  Future<void> trigger() async {
    loggy.debug("triggering update");
    _forceNextRun = true;
    await _scheduler?.trigger();
  }

  @visibleForTesting
  Future<void> updateProfiles() async {
    var force = false;
    if (_forceNextRun) {
      force = true;
      _forceNextRun = false;
    }

    final timestamps = ForegroundProfileRefreshTimestamps(ref.read(sharedPreferencesProvider).requireValue);
    final now = DateTime.now();
    if (!shouldStartForegroundProfileRefresh(
      force: force,
      lastAttempt: timestamps.lastAttempt,
      lastSuccess: timestamps.lastSuccess,
      now: now,
    )) {
      loggy.debug("too soon! last attempt: [${timestamps.lastAttempt}], last success: [${timestamps.lastSuccess}]");
      return;
    }
    await timestamps.recordAttempt(now);
    _retryTimer?.cancel();
    _retryTimer = null;
    loggy.debug(
      "${force ? "[FORCED] " : ""}running, last attempt: [${timestamps.lastAttempt}], "
      "last success: [${timestamps.lastSuccess}]",
    );

    var attemptedProfileUpdate = false;
    var allProfileUpdatesSucceeded = true;
    var cycleCompleted = false;
    try {
      // RULESET and remote profiles form one freshness transaction. Fetch the
      // policy first so every config generated by this cycle sees the same
      // active generation. The service remains fail-open and preserves its LKG
      // if the control plane is temporarily unavailable.
      await ref.read(managedRuleSetSyncServiceProvider).sync(force: true, reason: 'foreground_profile_cycle');

      final remoteProfiles = await ref
          .read(profileRepositoryProvider)
          .requireValue
          .watchAll()
          .map(
            (event) => event.getOrElse((f) {
              final stackTrace = switch (f) {
                UnexpectedFailure(:final stackTrace) => stackTrace,
                _ => null,
              };
              loggy.error("error getting profiles", f, stackTrace);
              throw f;
            }).whereType<RemoteProfileEntity>(),
          )
          .first;
      final proxyOnly = ref.read(connectionNotifierProvider).valueOrNull?.isConnected ?? false;

      await for (final profile in Stream.fromIterable(remoteProfiles)) {
        final normalizedProfileName = parseProfileName(profile.name).trim();
        final displayProfileName = normalizedProfileName.isNotEmpty ? normalizedProfileName : profile.name;
        final updateInterval = profile.options?.updateInterval;
        if (shouldRefreshProfileInUnifiedCycle(
          force: force,
          configuredUpdateInterval: updateInterval,
          lastUpdate: profile.lastUpdate,
          now: DateTime.now(),
        )) {
          attemptedProfileUpdate = true;
          final t = ref.read(translationsProvider).requireValue;
          final result = await ref
              .read(profileRepositoryProvider)
              .requireValue
              .upsertRemote(profile.url, proxyOnly: proxyOnly, syncManagedRuleSets: false)
              .mapLeft((l) {
                loggy.debug("error updating profile [${profile.id}]", l);
                ref
                    .read(inAppNotificationControllerProvider)
                    .showErrorToast(
                      t.presentShortError(
                        l,
                        action: t.pages.profiles.msg.update.failureNamed(name: displayProfileName),
                      ),
                      diagnosticText: t.diagnosticError(
                        l,
                        action: t.pages.profiles.msg.update.failureNamed(name: displayProfileName),
                      ),
                    );
                state = AsyncData((name: displayProfileName, success: false));
              })
              .map((_) {
                loggy.debug("profile [${profile.id}] updated successfully");
                ref
                    .read(inAppNotificationControllerProvider)
                    .showSuccessToast(t.pages.profiles.msg.update.successNamed(name: displayProfileName));
                state = AsyncData((name: displayProfileName, success: true));
              })
              .run();
          if (result.isLeft()) allProfileUpdatesSucceeded = false;
        } else {
          loggy.debug(
            "skipping profile [${profile.id}] update. last successful update: [${profile.lastUpdate}] - "
            "auto-update enabled: [${profile.options?.updateInterval != null}] - unified interval: [$interval]",
          );
        }
      }
      cycleCompleted = true;
    } finally {
      if (cycleCompleted && attemptedProfileUpdate && allProfileUpdatesSucceeded) {
        await timestamps.recordSuccess(DateTime.now());
        _consecutiveFailedCycles = 0;
      } else if (cycleCompleted && attemptedProfileUpdate) {
        _consecutiveFailedCycles++;
        _scheduleFailedCycleRetry();
      }
    }
  }

  void _scheduleFailedCycleRetry() {
    final delay = foregroundProfileRefreshRetryDelay(_consecutiveFailedCycles);
    loggy.debug("scheduling failed profile refresh retry in [$delay]");
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      final scheduler = _scheduler;
      if (scheduler != null) unawaited(scheduler.trigger());
    });
  }
}
