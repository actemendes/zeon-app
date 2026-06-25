import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/features/notifications/data/notification_repository.dart';
import 'package:hiddify/features/notifications/service/notifications_background.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:workmanager/workmanager.dart';

class NotificationPollingService with InfraLogger {
  NotificationPollingService({
    required NotificationRepository repository,
    required bool Function() notificationsEnabled,
  }) : _repository = repository,
       _notificationsEnabled = notificationsEnabled;

  static const androidPeriodicTaskName = 'zeon.notifications.poll';
  static const androidPeriodicUniqueName = 'zeon_notifications_periodic_poll';
  static const androidPeriodicInterval = Duration(minutes: 15);
  static const windowsPollingInterval = Duration(
    minutes: int.fromEnvironment('notifications_windows_polling_minutes', defaultValue: 5),
  );
  static const foregroundPollingInterval = Duration(minutes: 5);

  final NotificationRepository _repository;
  final bool Function() _notificationsEnabled;
  Timer? _timer;
  bool _started = false;
  bool _workManagerInitialized = false;
  int _failureCount = 0;
  DateTime? _nextAllowedAttempt;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _repository.initializeSystemNotifications();
    await configurePlatformSchedulers();
    await syncNow(force: true, trigger: 'startup');
    _startTimer();
  }

  Future<void> configurePlatformSchedulers() async {
    if (!PlatformUtils.isAndroid) return;
    if (!_workManagerInitialized) {
      await Workmanager().initialize(notificationWorkmanagerDispatcher);
      _workManagerInitialized = true;
    }
    if (!_notificationsEnabled()) {
      await Workmanager().cancelByUniqueName(androidPeriodicUniqueName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      androidPeriodicUniqueName,
      androidPeriodicTaskName,
      frequency: androidPeriodicInterval,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 1),
    );
  }

  Future<NotificationSyncReport?> syncNow({bool force = false, String trigger = 'manual'}) async {
    if (!force && !_canAttemptNow()) return null;
    if (!_notificationsEnabled()) return const NotificationSyncReport(disabled: true);
    try {
      final report = await _repository.sync(manual: force);
      _failureCount = 0;
      _nextAllowedAttempt = null;
      loggy.info(
        'notification sync complete [trigger=$trigger fetched=${report.fetched} displayed=${report.displayed} fallback_displayed=${report.fallbackDisplayed} failed=${report.failed} not_modified=${report.notModified}]',
      );
      return report;
    } on DioException catch (e, st) {
      _registerFailure();
      loggy.warning('notification sync failed [trigger=$trigger type=${e.type.name}]', e, st);
      return null;
    } catch (e, st) {
      _registerFailure();
      loggy.warning('notification sync failed [trigger=$trigger]', e, st);
      return null;
    }
  }

  Future<void> onForeground() => syncNow(force: true, trigger: 'foreground');

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _startTimer() {
    _timer?.cancel();
    final interval = PlatformUtils.isWindows ? windowsPollingInterval : foregroundPollingInterval;
    _timer = Timer.periodic(interval, (_) {
      unawaited(syncNow(trigger: 'timer'));
    });
  }

  bool _canAttemptNow() {
    final next = _nextAllowedAttempt;
    return next == null || !DateTime.now().toUtc().isBefore(next);
  }

  void _registerFailure() {
    _failureCount = (_failureCount + 1).clamp(1, 8);
    final seconds = (30 * (1 << (_failureCount - 1))).clamp(30, 900);
    _nextAllowedAttempt = DateTime.now().toUtc().add(Duration(seconds: seconds));
  }
}
