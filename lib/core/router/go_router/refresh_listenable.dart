import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/deep_linking/my_app_links.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';
import 'package:zeon/utils/custom_loggers.dart';

// For temporary storage of the link received from AppLinks.
String newUrlFromAppLink = '';

class RefreshListenable extends ChangeNotifier with InfraLogger, WidgetsBindingObserver {
  static const _externalSubscriptionRetryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 15),
    Duration(seconds: 45),
    Duration(seconds: 90),
  ];

  RefreshListenable(this.ref) {
    WidgetsBinding.instance.addObserver(this);
    ref.listen(myAppLinksProvider, (_, next) {
      final url = next.value;
      if (url == null || url.trim().isEmpty) return;

      newUrlFromAppLink = url;
      notifyListeners();
    });
    ref.listen(Preferences.introCompleted, (_, _) => notifyListeners());
    _startExternalSubscriptionRefresh(trigger: 'init', resetAttempts: true);
  }

  final Ref ref;
  Timer? _externalSubscriptionTimer;
  bool _externalSubscriptionRefreshInFlight = false;
  int _externalSubscriptionAttempt = 0;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _externalSubscriptionTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startExternalSubscriptionRefresh(trigger: 'resume', resetAttempts: true);
    }
  }

  void _startExternalSubscriptionRefresh({required String trigger, required bool resetAttempts}) {
    final syncService = ref.read(externalSubscriptionSyncServiceProvider);
    if (!syncService.hasPendingExternalAccountReturn) return;
    if (resetAttempts) {
      _externalSubscriptionAttempt = 0;
      _externalSubscriptionTimer?.cancel();
    }
    loggy.info('external subscription refresh scheduled [trigger=$trigger]');
    _scheduleNextExternalSubscriptionAttempt(trigger: trigger);
  }

  void _scheduleNextExternalSubscriptionAttempt({required String trigger}) {
    if (_externalSubscriptionAttempt >= _externalSubscriptionRetryDelays.length) {
      loggy.info('external subscription refresh stopped [reason=attempts_exhausted]');
      unawaited(ref.read(externalSubscriptionSyncServiceProvider).finishPendingCheck());
      return;
    }

    final delay = _externalSubscriptionRetryDelays[_externalSubscriptionAttempt];
    _externalSubscriptionAttempt += 1;
    _externalSubscriptionTimer?.cancel();
    _externalSubscriptionTimer = Timer(delay, () => unawaited(_runExternalSubscriptionRefresh(trigger: trigger)));
  }

  Future<void> _runExternalSubscriptionRefresh({required String trigger}) async {
    if (_externalSubscriptionRefreshInFlight) return;
    _externalSubscriptionRefreshInFlight = true;
    try {
      final result = await ref.read(externalSubscriptionSyncServiceProvider).refreshPendingSubscription();
      loggy.info(
        'external subscription refresh attempt completed '
        '[trigger=$trigger attempt=$_externalSubscriptionAttempt result=${result.name}]',
      );
      switch (result) {
        case ExternalSubscriptionSyncResult.changed || ExternalSubscriptionSyncResult.skipped:
          _externalSubscriptionTimer?.cancel();
        case ExternalSubscriptionSyncResult.unchanged || ExternalSubscriptionSyncResult.failed:
          _scheduleNextExternalSubscriptionAttempt(trigger: trigger);
      }
    } catch (error, stackTrace) {
      loggy.warning('external subscription refresh attempt failed [trigger=$trigger]', error, stackTrace);
      _scheduleNextExternalSubscriptionAttempt(trigger: trigger);
    } finally {
      _externalSubscriptionRefreshInFlight = false;
    }
  }
}
