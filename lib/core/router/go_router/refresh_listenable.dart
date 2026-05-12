import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/deep_linking/my_app_links.dart';
import 'package:hiddify/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:hiddify/features/mobile/data/mobile_payment_deep_link.dart';
import 'package:hiddify/features/mobile/data/mobile_payment_service.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// For temporary storage of the link received from AppLinks.
String newUrlFromAppLink = '';
String? _lastProcessedPaymentSid;

class RefreshListenable extends ChangeNotifier with InfraLogger, WidgetsBindingObserver {
  static const _backgroundRecoveryInterval = Duration(seconds: 45);
  static const _backgroundRecoveryMaxAttempts = 20;

  RefreshListenable(this.ref) {
    WidgetsBinding.instance.addObserver(this);
    ref.listen(myAppLinksProvider, (_, next) {
      final url = next.value;
      if (url == null || url.trim().isEmpty) return;

      newUrlFromAppLink = url;
      _maybeHandlePaymentDeepLink(url);
      notifyListeners();
    });
    ref.listen(Preferences.introCompleted, (_, _) => notifyListeners());
    unawaited(_recoverPendingPaymentSession(trigger: "init", immediate: false));
  }
  final Ref ref;
  Timer? _recoveryTimer;
  bool _isRecoveryInFlight = false;
  int _recoveryAttemptsLeft = 0;
  String? _activeRecoverySid;
  String? _lastSuccessToastSid;
  String? _lastUpdateProfileRefreshSid;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRecoveryTimer();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverPendingPaymentSession(trigger: "resume", immediate: true));
    }
  }

  void _maybeHandlePaymentDeepLink(String rawUrl) {
    final sid = extractPaymentSessionIdFromDeepLink(rawUrl);
    if (sid == null || sid == _lastProcessedPaymentSid) {
      return;
    }
    _lastProcessedPaymentSid = sid;
    loggy.info("mobile payment deep link captured in router listener [sid=$sid]");
    unawaited(_startRecoveryForSid(sid, trigger: "deeplink", immediate: true, resetAttempts: true));
  }

  Future<void> _recoverPendingPaymentSession({required String trigger, required bool immediate}) async {
    try {
      final paymentService = _buildPaymentService();
      final sid = await paymentService.getRecoverablePaymentSessionId();
      if (sid == null) {
        _activeRecoverySid = null;
        _stopRecoveryTimer();
        return;
      }
      await _startRecoveryForSid(sid, trigger: trigger, immediate: immediate, resetAttempts: _activeRecoverySid != sid);
    } catch (e, st) {
      loggy.warning("mobile payment recovery preload failed [trigger=$trigger]", e, st);
    }
  }

  Future<void> _startRecoveryForSid(
    String sid, {
    required String trigger,
    required bool immediate,
    required bool resetAttempts,
  }) async {
    _activeRecoverySid = sid;
    if (resetAttempts || _recoveryAttemptsLeft <= 0) {
      _recoveryAttemptsLeft = _backgroundRecoveryMaxAttempts;
    }
    _ensureRecoveryTimer();
    if (immediate) {
      await _runSingleRecoveryAttempt(sid, trigger: trigger, maxStatusAttempts: 7);
    }
  }

  MobilePaymentService _buildPaymentService() {
    return MobilePaymentService(
      httpClient: ref.read(httpClientProvider),
      preferences: ref.read(sharedPreferencesProvider).requireValue,
      connLinkImportService: ref.read(mobileConnLinkImportServiceProvider),
    );
  }

  void _ensureRecoveryTimer() {
    _recoveryTimer ??= Timer.periodic(_backgroundRecoveryInterval, (_) {
      unawaited(_tickBackgroundRecovery());
    });
  }

  void _stopRecoveryTimer() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }

  Future<void> _tickBackgroundRecovery() async {
    if (_recoveryAttemptsLeft <= 0) {
      loggy.info("mobile payment background recovery stopped [reason=attempts_exhausted]");
      _stopRecoveryTimer();
      return;
    }
    final paymentService = _buildPaymentService();
    final sid = await paymentService.getRecoverablePaymentSessionId();
    if (sid == null) {
      _activeRecoverySid = null;
      _stopRecoveryTimer();
      return;
    }
    if (_activeRecoverySid != sid) {
      _activeRecoverySid = sid;
      _recoveryAttemptsLeft = _backgroundRecoveryMaxAttempts;
      loggy.info("mobile payment background recovery switched sid [sid=$sid]");
    }
    await _runSingleRecoveryAttempt(sid, trigger: "background_timer", maxStatusAttempts: 2);
  }

  Future<void> _runSingleRecoveryAttempt(String sid, {required String trigger, required int maxStatusAttempts}) async {
    if (_isRecoveryInFlight) return;
    if (_recoveryAttemptsLeft <= 0) return;
    _isRecoveryInFlight = true;
    _recoveryAttemptsLeft -= 1;
    try {
      final paymentService = _buildPaymentService();
      final result = await paymentService.processPaymentSessionReturn(sid: sid, maxAttempts: maxStatusAttempts);
      final remoteProfileRefreshed = await _maybeRefreshActiveRemoteProfileFromNotifier(
        sid: sid,
        result: result,
        trigger: trigger,
      );
      loggy.info(
        "mobile payment recovery attempt finished "
        "[sid=$sid, trigger=$trigger, state=${result.state.name}, refresh_triggered=${result.refreshTriggered}, "
        "active_profile_refreshed=$remoteProfileRefreshed, attempts_left=$_recoveryAttemptsLeft]",
      );
      _maybeShowPaymentSuccessToast(sid: sid, trigger: trigger, result: result);
      if (result.state != PaymentSessionState.pending) {
        _activeRecoverySid = null;
        _stopRecoveryTimer();
      }
    } catch (e, st) {
      loggy.warning("mobile payment recovery attempt failed [sid=$sid, trigger=$trigger]", e, st);
    } finally {
      _isRecoveryInFlight = false;
    }
  }

  void _maybeShowPaymentSuccessToast({
    required String sid,
    required String trigger,
    required PaymentSessionProcessResult result,
  }) {
    if (result.state != PaymentSessionState.succeeded || !result.refreshTriggered) return;
    if (_lastSuccessToastSid == sid) return;
    _lastSuccessToastSid = sid;

    final t = ref.read(translationsProvider).valueOrNull;
    final suffix = t?.pages.profiles.msg.update.success;
    final message = (suffix == null || suffix.trim().isEmpty)
        ? "Оплата прошла успешно, профиль обновлен"
        : "Оплата прошла успешно. $suffix";
    ref.read(inAppNotificationControllerProvider).showSuccessToast(message);
    loggy.info("mobile payment success toast shown [sid=$sid, trigger=$trigger]");
  }

  Future<bool> _maybeRefreshActiveRemoteProfileFromNotifier({
    required String sid,
    required PaymentSessionProcessResult result,
    required String trigger,
  }) async {
    if (result.state != PaymentSessionState.succeeded) return false;
    if (_lastUpdateProfileRefreshSid == sid) return false;
    try {
      final active = await ref.read(activeProfileProvider.future);
      if (active is! RemoteProfileEntity) {
        loggy.warning(
          "mobile payment success: skipped active profile refresh, active is not remote "
          "[sid=$sid, trigger=$trigger, active_type=${active?.runtimeType}]",
        );
        return false;
      }
      await ref.read(updateProfileNotifierProvider(active.id).notifier).updateProfile(active);
      _lastUpdateProfileRefreshSid = sid;
      loggy.info(
        "mobile payment success: active remote profile refreshed via update notifier "
        "[sid=$sid, trigger=$trigger, profile_id=${active.id}]",
      );
      return true;
    } catch (e, st) {
      loggy.warning("mobile payment success: active profile refresh via update notifier failed [sid=$sid]", e, st);
      return false;
    }
  }
}
