import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:zeon/core/haptic/haptic_service.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/model/failures.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/features/connection/data/connection_data_providers.dart';
import 'package:zeon/features/connection/data/connection_repository.dart';
import 'package:zeon/features/connection/model/connection_failure.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/diagnostics/data/diagnostics_providers.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/profile/data/profile_data_mapper.dart';
import 'package:zeon/features/profile/data/profile_data_providers.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
  static const _disconnectingResyncDelay = Duration(seconds: 2);
  static const _platformResyncTimeout = Duration(seconds: 2);
  static const _mainButtonResyncTimeout = Duration(milliseconds: 800);
  static const _disconnectingResyncAttempts = 3;
  static const _missingProfileRecheckDelay = Duration(milliseconds: 500);
  static const _missingProfileRecheckAttempts = 6;
  static const _embeddedPromotionDelays = <Duration>[
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
    Duration(seconds: 13),
    Duration(seconds: 21),
  ];
  static const _embeddedPromotionSlowRetryDelay = Duration(seconds: 30);
  static const _embeddedPromotionMaxReachableImportFailures = 3;

  bool get _useMockConnectionFlow => kIsWeb && kDebugMode && _debugSeedProfileEnabled;

  int _mockConnectAttempts = 0;
  Future<void>? _embeddedPromotionInFlight;
  Future<void>? _missingProfileReconcileInFlight;
  bool _embeddedPromotionControlsReconnect = false;
  String? _connectedProfileId;
  ConnectionStatus? _lastObservedConnectionStatus;
  bool _connectionWasUp = false;
  String? _lastUserAction;
  DateTime? _lastUserActionAt;
  int? _expectedStopIntentEpoch;
  AppLifecycleListener? _appLifecycleListener;
  int _connectionIntentEpoch = 0;
  bool? _desiredRunning;
  int? _timedOutConnectingIntentEpoch;
  int? _timedOutDisconnectingIntentEpoch;
  int _mainButtonStartAttemptSequence = 0;
  int? _mainButtonStartInFlightToken;
  int? _mainButtonStartIntentEpoch;
  int _mainButtonStopAttemptSequence = 0;
  int? _mainButtonStopInFlightToken;
  int? _mainButtonStopIntentEpoch;

  @override
  Stream<ConnectionStatus> build() async* {
    _appLifecycleListener ??= AppLifecycleListener(onResume: () => unawaited(_resyncFromPlatform("app_resume")));
    ref.onDispose(() {
      _appLifecycleListener?.dispose();
      _appLifecycleListener = null;
    });
    if (!kIsWeb && Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
      unawaited(_prepareSystemVpnForActiveProfile());
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      final wasConnected = switch (previous) {
        AsyncData(value: final Connected _) => true,
        _ => false,
      };
      final isConnected = switch (next) {
        AsyncData(value: final Connected _) => true,
        _ => false,
      };
      if (isConnected && !wasConnected) {
        await ref.read(hapticServiceProvider.notifier).heavyImpact();

        if (!kIsWeb && Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
          if (await InAppReview.instance.isAvailable()) {
            InAppReview.instance.requestReview();
            ref.read(Preferences.storeReviewedByUser.notifier).update(true);
          }
        }

        unawaited(_promoteEmbeddedBootstrapProfileAfterConnection());
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (_embeddedPromotionControlsReconnect) return;
      if (!shouldReconnectForActiveProfileChange(
        connected: _isConnected,
        connectedProfileId: _connectedProfileId,
        nextProfileId: next?.id,
      )) {
        return;
      }
      await reconnect(next);
    });
    if (_useMockConnectionFlow) {
      yield const Disconnected();
      return;
    }
    await for (final event in _connectionRepo.watchConnectionStatus()) {
      if (!_acceptPlatformStatus(event)) {
        loggy.info(
          "event=stale_ui_status_ignored status=${event.runtimeType} "
          "intent=$_connectionIntentEpoch desired_running=$_desiredRunning",
        );
        continue;
      }

      if (event is Connected || event is Disconnected) {
        // The command has reached a terminal platform observation. Do not let
        // unrelated trailing work in the original Connect Future keep the
        // button's duplicate-start latch closed for the rest of the process.
        _releaseMainButtonStart();
      }
      if (event is Disconnected) {
        // Native has reached a terminal Stop even if the original Dart Future
        // is still cleaning streams/resources. A later session must not be
        // blocked by that old Future's duplicate-stop latch.
        _releaseMainButtonStop();
      }

      final previousStatus = _lastObservedConnectionStatus;
      final wasUpBefore = _connectionWasUp;
      final startedByUser = ref.read(Preferences.startedByUser);

      if (event case Connected()) {
        _connectionWasUp = true;
      } else if (event case Disconnected()) {
        // A platform-owned notification/tile Stop clears the shared intent
        // before publishing DISCONNECTED, so it is not an unexpected outage.
        final expectedRunning = startedByUser;
        final nativeSnapshot = ref.read(vpnSessionSnapshotSourceProvider).current;
        if (_shouldCaptureUnexpectedDisconnect(
          event,
          wasUpBefore: wasUpBefore,
          expectedRunning: expectedRunning,
          nativeSnapshot: nativeSnapshot,
        )) {
          try {
            unawaited(
              ref
                  .read(errorReportControllerProvider)
                  .captureUnexpectedVpnDisconnect(
                    previousStatus: previousStatus,
                    disconnected: event,
                    lastUserAction: _lastUserAction,
                    lastUserActionAt: _lastUserActionAt,
                    startedByUser: expectedRunning,
                  ),
            );
          } catch (error, stackTrace) {
            loggy.warning("failed to capture unexpected VPN disconnect", error, stackTrace);
          }
        }
        _connectionWasUp = false;
        _expectedStopIntentEpoch = null;

        // Android notification/tile Stop is outside this notifier. The native
        // owner persists startedByUser=false before publishing DISCONNECTED;
        // adopt that terminal user intent without mistaking an unexpected
        // disconnect (where the preference remains true) for a manual Stop.
        if (!startedByUser && _desiredRunning != false) {
          _beginConnectionIntent(running: false);
        }
      }

      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      if (PlatformUtils.isIOS) {
        switch (event) {
          case Connected():
            ref.read(Preferences.startedByUser.notifier).update(true);
          case Disconnected():
            ref.read(Preferences.startedByUser.notifier).update(false);
          default:
            break;
        }
      }
      _lastObservedConnectionStatus = event;
      loggy.info("connection status: ${event.format()}");
      if (event case Connected() when previousStatus is! Connected) {
        unawaited(_promoteEmbeddedBootstrapProfileAfterConnection());
      }
      yield event;
    }
  }

  bool _acceptPlatformStatus(ConnectionStatus status) {
    // Once Stop is the newest intent, callbacks from an older connect/restart
    // must not revive the UI. Core generations perform the primary filtering;
    // this is the final UI-side guard for already queued stream callbacks.
    if (status is Connecting && _timedOutConnectingIntentEpoch == _connectionIntentEpoch) {
      return false;
    }
    if (status is Disconnecting && _timedOutDisconnectingIntentEpoch == _connectionIntentEpoch) {
      return false;
    }
    final nativeSnapshot = ref.read(vpnSessionSnapshotSourceProvider).current;
    if (shouldIgnoreTransientStopDuringStart(
      desiredRunning: _desiredRunning,
      status: status,
      nativeSnapshot: nativeSnapshot,
    )) {
      return false;
    }
    if (_desiredRunning == false && (status is Connecting || status is Connected)) {
      // A platform-owned tile/shortcut start is authoritative and updates the
      // shared Riverpod intent before publishing its proven Connected snapshot.
      if (status is Connected && ref.read(Preferences.startedByUser)) {
        _beginConnectionIntent(running: true);
        return true;
      }
      return false;
    }
    return true;
  }

  Future<ConnectionStatus?> _resyncFromPlatform(
    String source, {
    int? intentEpoch,
    bool Function(ConnectionStatus authoritative)? shouldApply,
  }) async {
    if (_useMockConnectionFlow) return null;
    final requestedAtIntent = intentEpoch ?? _connectionIntentEpoch;
    try {
      final authoritative = await _connectionRepo
          .resyncConnectionStatus(source)
          .timeout(_platformResyncTimeout, onTimeout: () => null);
      if (authoritative == null) return null;
      if (requestedAtIntent != _connectionIntentEpoch) {
        loggy.info(
          "event=stale_ui_resync_ignored source=$source "
          "intent=$requestedAtIntent current_intent=$_connectionIntentEpoch",
        );
        return authoritative;
      }
      if (shouldApply != null && !shouldApply(authoritative)) return authoritative;
      if (!_acceptPlatformStatus(authoritative)) return authoritative;
      final current = state.asData?.value;
      if (current != authoritative) {
        loggy.info("event=vpn_ui_resync source=$source from=${current?.runtimeType} to=${authoritative.runtimeType}");
        state = AsyncData(authoritative);
      }
      return authoritative;
    } catch (e, st) {
      loggy.warning("VPN snapshot resync failed [$source]", e, st);
      return null;
    }
  }

  Future<void> _boundedConnectingResync(int intentEpoch) async {
    await Future<void>.delayed(const Duration(seconds: 12));
    if (!_isCurrentIntent(intentEpoch, running: true) || state.asData?.value is! Connecting) return;
    await _resyncFromPlatform(
      "connecting_timeout",
      intentEpoch: intentEpoch,
      shouldApply: (_) => _isCurrentIntent(intentEpoch, running: true) && state.asData?.value is Connecting,
    );
    if (_isCurrentIntent(intentEpoch, running: true) && state.asData?.value is Connecting) {
      const failure = ConnectionFailure.unexpected(
        "VPN start status could not be confirmed within the recovery deadline",
      );
      loggy.warning("event=vpn_ui_connecting_timeout intent=$intentEpoch");
      _timedOutConnectingIntentEpoch = intentEpoch;
      _releaseMainButtonStart(intentEpoch: intentEpoch);
      state = AsyncError(failure, StackTrace.current);
    }
  }

  Future<void> _boundedDisconnectingResync(int intentEpoch) async {
    for (var attempt = 1; attempt <= _disconnectingResyncAttempts; attempt++) {
      await Future<void>.delayed(_disconnectingResyncDelay);
      if (!_isCurrentIntent(intentEpoch, running: false) || state.asData?.value is! Disconnecting) return;
      final authoritative = await _resyncFromPlatform(
        "disconnecting_timeout_$attempt",
        intentEpoch: intentEpoch,
        shouldApply: (status) => _isCurrentIntent(intentEpoch, running: false) && status is Disconnected,
      );
      if (authoritative is Disconnected) return;
    }
    if (!_isCurrentIntent(intentEpoch, running: false) || state.asData?.value is! Disconnecting) return;
    const failure = ConnectionFailure.unexpected(
      "VPN stop status could not be confirmed within the recovery deadline; tap to retry",
    );
    loggy.warning("event=vpn_ui_disconnecting_timeout intent=$intentEpoch");
    _timedOutDisconnectingIntentEpoch = intentEpoch;
    _releaseMainButtonStop(intentEpoch: intentEpoch);
    state = AsyncError(failure, StackTrace.current);
    try {
      unawaited(ref.read(errorReportControllerProvider).captureConnectionFailure(failure, StackTrace.current));
    } catch (error, stackTrace) {
      loggy.warning("failed to capture disconnect watchdog failure", error, stackTrace);
    }
  }

  int _beginConnectionIntent({required bool running}) {
    _connectionIntentEpoch += 1;
    _desiredRunning = running;
    _timedOutConnectingIntentEpoch = null;
    _timedOutDisconnectingIntentEpoch = null;
    _releaseSupersededMainButtonAttempts();
    return _connectionIntentEpoch;
  }

  int _beginStartIntent() {
    final intentEpoch = _beginConnectionIntent(running: true);
    state = const AsyncData(Connecting());
    unawaited(_boundedConnectingResync(intentEpoch));
    return intentEpoch;
  }

  int _beginStopIntent() {
    final intentEpoch = _beginConnectionIntent(running: false);
    state = const AsyncData(Disconnecting());
    unawaited(_boundedDisconnectingResync(intentEpoch));
    return intentEpoch;
  }

  Future<void> _dispatchStopIntent(int intentEpoch, {Future<void> Function()? haptic, bool force = false}) async {
    // Native Stop is dispatched before haptics or preference I/O. In
    // particular, it never waits behind a hung automatic reconnect.
    final stop = _disconnect(intentEpoch, force: force);
    if (haptic != null) {
      unawaited(_runLifecycleSideEffect(haptic, "stop haptic"));
    }
    final persistStoppedIntent = _runLifecycleSideEffect(
      () => ref.read(Preferences.startedByUser.notifier).update(false),
      "persist stopped intent",
    );
    try {
      await stop;
    } finally {
      await persistStoppedIntent;
    }
  }

  Future<void> _runLifecycleSideEffect(Future<void> Function() action, String name) async {
    try {
      await action().timeout(const Duration(seconds: 1));
    } catch (error, stackTrace) {
      loggy.warning("$name failed; continuing with the VPN lifecycle command", error, stackTrace);
    }
  }

  bool _isCurrentIntent(int intentEpoch, {required bool running}) {
    return intentEpoch == _connectionIntentEpoch && _desiredRunning == running;
  }

  bool _isActiveStartIntent(int intentEpoch) {
    return _isCurrentIntent(intentEpoch, running: true) && _timedOutConnectingIntentEpoch != intentEpoch;
  }

  bool get hasPendingStopIntent => _desiredRunning == false;

  bool? get desiredRunning => _desiredRunning;

  bool get hasRetryableStopError => state.hasError && _timedOutDisconnectingIntentEpoch == _connectionIntentEpoch;

  @visibleForTesting
  int get connectionIntentEpochForTesting => _connectionIntentEpoch;

  @visibleForTesting
  bool? get desiredRunningForTesting => desiredRunning;

  @visibleForTesting
  bool get mainButtonStopInFlightForTesting => _mainButtonStopInFlightToken != null;

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> _prepareSystemVpnForActiveProfile() async {
    try {
      final activeProfile = await ref.read(activeProfileProvider.future);
      if (activeProfile == null) return;
      await _connectionRepo
          .prepareSystemVpn(activeProfile, ref.read(Preferences.disableMemoryLimit))
          .mapLeft((err) => loggy.warning("error preparing system VPN configuration", err))
          .run();
    } catch (e, st) {
      loggy.warning("error preparing system VPN configuration", e, st);
    }
  }

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) {
        final intentEpoch = _beginStartIntent();
        return _connect(intentEpoch);
      }
    }
  }

  /// Starts the same connection flow as a user tap after an API request could
  /// not reach the service over the ordinary network.
  Future<bool> connectForApiRecovery() async {
    if (state.asData?.value case Connected() || Connecting()) return true;
    if (state.asData?.value case Disconnecting()) return false;

    final intentEpoch = _beginStartIntent();
    final activeProfile = ref.read(activeProfileProvider).valueOrNull;
    if (!_isCurrentIntent(intentEpoch, running: true)) return false;
    if (activeProfile == null) {
      loggy.warning("API VPN recovery skipped: no active profile");
      if (_isCurrentIntent(intentEpoch, running: true)) {
        _desiredRunning = false;
        _releaseMainButtonStart();
        state = const AsyncData(Disconnected());
      }
      await ref.read(dialogNotifierProvider.notifier).showNoActiveProfile();
      return false;
    }

    _markUserAction('api_recovery_connect');
    await _runLifecycleSideEffect(
      () => ref.read(Preferences.startedByUser.notifier).update(true),
      "persist API recovery start intent",
    );
    if (!_isCurrentIntent(intentEpoch, running: true)) return false;
    await _connect(intentEpoch);
    return true;
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      if (_desiredRunning == false) {
        final force = _timedOutDisconnectingIntentEpoch != null;
        final intentEpoch = _beginStopIntent();
        _markUserAction('retry_disconnect_after_error', expectsStop: true);
        return _dispatchStopIntent(intentEpoch, haptic: haptic.mediumImpact, force: force);
      }
      final intentEpoch = _beginStartIntent();
      unawaited(_runLifecycleSideEffect(haptic.lightImpact, "start haptic"));
      if (!_isCurrentIntent(intentEpoch, running: true)) return;
      await _connect(intentEpoch);
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          final intentEpoch = _beginStartIntent();
          unawaited(_runLifecycleSideEffect(haptic.lightImpact, "start haptic"));
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          _markUserAction('manual_connect');
          await _runLifecycleSideEffect(
            () => ref.read(Preferences.startedByUser.notifier).update(true),
            "persist started intent",
          );
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          await _connect(intentEpoch);
        case Connected():
          // default:
          final intentEpoch = _beginStopIntent();
          _markUserAction('manual_disconnect', expectsStop: true);
          await _dispatchStopIntent(intentEpoch, haptic: haptic.mediumImpact);
        case Connecting():
          final intentEpoch = _beginStopIntent();
          _markUserAction('cancel_pending_connect', expectsStop: true);
          await _dispatchStopIntent(intentEpoch, haptic: haptic.mediumImpact);
        case Disconnecting():
          final intentEpoch = _beginStopIntent();
          _markUserAction('retry_disconnect', expectsStop: true);
          await _dispatchStopIntent(intentEpoch, haptic: haptic.mediumImpact);
      }
    }
  }

  Future<void> handleMainVpnButtonTap(
    MainVpnButtonState displayedState, {
    Future<bool> Function()? confirmStart,
  }) async {
    final authoritative = await _authoritativeMainButtonState('main_button_tap');
    if (authoritative == null) return;
    if (authoritative != displayedState) {
      loggy.info(
        'event=main_button_snapshot_resync '
        'displayed=${displayedState.phase.name}/${displayedState.generation} '
        'authoritative=${authoritative.phase.name}/${authoritative.generation}',
      );
    }

    switch (authoritative.action) {
      case MainVpnButtonAction.start:
        if (authoritative.blocksStart || _mainButtonStartInFlightToken != null) return;
        final startAttemptToken = ++_mainButtonStartAttemptSequence;
        _mainButtonStartInFlightToken = startAttemptToken;
        _mainButtonStartIntentEpoch = null;
        try {
          if (confirmStart != null) {
            final confirmed = await confirmStart();
            if (_mainButtonStartInFlightToken != startAttemptToken || !confirmed) return;
            // Dialogs/profile selection are asynchronous. Re-read the native
            // owner after them so an external start cannot be followed by a
            // stale second START from this tap. Normal one-tap starts reuse
            // the first fence and avoid another potential 800 ms wait.
            final afterConfirmation = await _authoritativeMainButtonState('main_button_before_start');
            if (_mainButtonStartInFlightToken != startAttemptToken ||
                afterConfirmation == null ||
                afterConfirmation.action != MainVpnButtonAction.start ||
                afterConfirmation.blocksStart) {
              return;
            }
          }
          if (_mainButtonStartInFlightToken != startAttemptToken) return;
          final intentEpoch = _beginStartIntent();
          if (_mainButtonStartInFlightToken == startAttemptToken) {
            _mainButtonStartIntentEpoch = intentEpoch;
          }
          unawaited(_runLifecycleSideEffect(ref.read(hapticServiceProvider.notifier).lightImpact, "start haptic"));
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          _markUserAction('manual_connect');
          await _runLifecycleSideEffect(
            () => ref.read(Preferences.startedByUser.notifier).update(true),
            "persist started intent",
          );
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          await _connect(intentEpoch);
        } finally {
          // A watchdog or terminal platform event may already have released
          // this attempt and allowed a retry. The old Future must never unlock
          // that newer retry when it eventually completes.
          if (_mainButtonStartInFlightToken == startAttemptToken) {
            _releaseMainButtonStart();
          }
        }
        return;
      case MainVpnButtonAction.stop:
        if (_mainButtonStopInFlightToken != null) return;
        final force = state.hasError && _desiredRunning == false && _timedOutDisconnectingIntentEpoch != null;
        final stopAttemptToken = ++_mainButtonStopAttemptSequence;
        _mainButtonStopInFlightToken = stopAttemptToken;
        _mainButtonStopIntentEpoch = null;
        try {
          final intentEpoch = _beginStopIntent();
          if (_mainButtonStopInFlightToken == stopAttemptToken) {
            _mainButtonStopIntentEpoch = intentEpoch;
          }
          _markUserAction(authoritative.isStarting ? 'cancel_pending_connect' : 'manual_disconnect', expectsStop: true);
          await _dispatchStopIntent(
            intentEpoch,
            haptic: ref.read(hapticServiceProvider.notifier).mediumImpact,
            force: force,
          );
        } finally {
          if (_mainButtonStopInFlightToken == stopAttemptToken) {
            _releaseMainButtonStop();
          }
        }
        return;
      case MainVpnButtonAction.none:
        return;
    }
  }

  Future<MainVpnButtonState?> _authoritativeMainButtonState(String source) async {
    final snapshotSource = ref.read(vpnSessionSnapshotSourceProvider);
    try {
      final snapshot = await snapshotSource.resync(source).timeout(_mainButtonResyncTimeout);
      if (snapshot != null) {
        return _reconcileMainButtonState(snapshot);
      }
      if (!shouldFailClosedMainButtonSnapshotResync(isMobile: PlatformUtils.isMobile)) {
        return _reconcileMainButtonState(snapshotSource.current);
      }
      return null;
    } catch (error, stackTrace) {
      loggy.warning('main VPN button snapshot resync failed [$source]', error, stackTrace);
      // Fail closed on both mobile snapshot platforms. A cached value may be
      // the opposite of the current Settings/Control Center state after the
      // Runner was suspended, so it cannot authorize either START or STOP.
      if (shouldFailClosedMainButtonSnapshotResync(isMobile: PlatformUtils.isMobile)) return null;
      return _reconcileMainButtonState(snapshotSource.current);
    }
  }

  MainVpnButtonState _reconcileMainButtonState(VpnSessionSnapshot? snapshot) {
    final buttonState = MainVpnButtonState.fromSources(
      snapshot: snapshot,
      localStatus: state.valueOrNull,
      localDesiredRunning: _desiredRunning,
      localStopRetry: hasRetryableStopError,
      localLoading: state.isLoading,
      localHasError: state.hasError,
    );
    final startIntentEpoch = _mainButtonStartIntentEpoch;
    if (startIntentEpoch != null &&
        (startIntentEpoch != _connectionIntentEpoch ||
            buttonState.isConnected ||
            buttonState.phase == VpnSessionPhase.failed ||
            (buttonState.action == MainVpnButtonAction.start && !buttonState.isStarting))) {
      // A direct snapshot read can observe the terminal platform state even
      // if the legacy status stream was suspended in the background. Release
      // the old START latch before deciding this tap.
      _releaseMainButtonStart(intentEpoch: startIntentEpoch);
    }
    final stopIntentEpoch = _mainButtonStopIntentEpoch;
    if (stopIntentEpoch != null &&
        (stopIntentEpoch != _connectionIntentEpoch ||
            buttonState.phase == VpnSessionPhase.failed ||
            (buttonState.action == MainVpnButtonAction.start && !buttonState.isStarting))) {
      _releaseMainButtonStop(intentEpoch: stopIntentEpoch);
    }
    return buttonState;
  }

  void _releaseMainButtonStart({int? intentEpoch}) {
    if (intentEpoch != null && _mainButtonStartIntentEpoch != intentEpoch) return;
    _mainButtonStartInFlightToken = null;
    _mainButtonStartIntentEpoch = null;
  }

  void _releaseMainButtonStop({int? intentEpoch}) {
    if (intentEpoch != null && _mainButtonStopIntentEpoch != intentEpoch) return;
    _mainButtonStopInFlightToken = null;
    _mainButtonStopIntentEpoch = null;
  }

  void _releaseSupersededMainButtonAttempts() {
    final startIntentEpoch = _mainButtonStartIntentEpoch;
    if (startIntentEpoch != null && startIntentEpoch != _connectionIntentEpoch) {
      _releaseMainButtonStart(intentEpoch: startIntentEpoch);
    }
    final stopIntentEpoch = _mainButtonStopIntentEpoch;
    if (stopIntentEpoch != null && stopIntentEpoch != _connectionIntentEpoch) {
      _releaseMainButtonStop(intentEpoch: stopIntentEpoch);
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        return _reconcileTemporarilyMissingProfile();
      }
      if (_useMockConnectionFlow) {
        loggy.info("mock reconnect");
        return _mockReconnectFlow();
      }
      if (_desiredRunning == false) return;
      final intentEpoch = _beginConnectionIntent(running: true);
      loggy.info("active profile changed, reconnecting");
      _markUserAction('profile_reconnect', expectsStop: true);
      final previousProfileId = _connectedProfileId;
      _connectedProfileId = profile.id;
      final result = await _connectionRepo
          .reconnect(profile, ref.read(Preferences.disableMemoryLimit), source: "profile_switch")
          .run();
      await result.match(
        (err) => Future<void>.sync(() {
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          _connectedProfileId = previousProfileId;
          _publishConnectionFailure(err, source: "profile_reconnect");
        }),
        (_) => _resyncFromPlatform(
          "profile_reconnect_completion",
          intentEpoch: intentEpoch,
          shouldApply: (_) => _isCurrentIntent(intentEpoch, running: true),
        ),
      );
    }
  }

  Future<void> restartForConfigChange(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        return _reconcileTemporarilyMissingProfile();
      }
      if (_useMockConnectionFlow) {
        loggy.info("mock config change restart");
        return _mockReconnectFlow();
      }
      if (_desiredRunning == false) return;
      final intentEpoch = _beginConnectionIntent(running: true);
      loggy.info("config options changed, restarting connection");
      _markUserAction('config_restart', expectsStop: true);
      final result = await _connectionRepo
          .reconnect(profile, ref.read(Preferences.disableMemoryLimit), source: "mode_switch")
          .run();
      await result.match(
        (err) => Future<void>.sync(() {
          if (!_isCurrentIntent(intentEpoch, running: true)) return;
          _publishConnectionFailure(err, source: "config_restart");
        }),
        (_) => _resyncFromPlatform(
          "mode_reconnect_completion",
          intentEpoch: intentEpoch,
          shouldApply: (_) => _isCurrentIntent(intentEpoch, running: true),
        ),
      );
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting() || Disconnecting():
          final intentEpoch = _beginStopIntent();
          loggy.debug("aborting connection");
          _markUserAction('abort_connection', expectsStop: true);
          await _dispatchStopIntent(intentEpoch);
        default:
      }
    }
  }

  Future<void> _reconcileTemporarilyMissingProfile() async {
    final existing = _missingProfileReconcileInFlight;
    if (existing != null) return existing;
    final operation = _reconcileTemporarilyMissingProfileInternal();
    _missingProfileReconcileInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_missingProfileReconcileInFlight, operation)) {
        _missingProfileReconcileInFlight = null;
      }
    }
  }

  Future<void> _reconcileTemporarilyMissingProfileInternal() async {
    loggy.info("active profile is temporarily null; deferring VPN reconciliation");
    for (var attempt = 1; attempt <= _missingProfileRecheckAttempts; attempt++) {
      await Future<void>.delayed(_missingProfileRecheckDelay);
      if (_desiredRunning == false || !_isConnected) return;
      final restored = ref.read(activeProfileProvider).valueOrNull;
      if (restored != null) {
        // A subscription transaction may replace a row without changing its
        // id. Reconnect explicitly so the running core cannot keep the old
        // config merely because id-based provider filtering suppressed it.
        loggy.info("active profile restored after a transient null; reconciling running VPN");
        await reconnect(restored);
        return;
      }
    }
    if (_desiredRunning == false || !_isConnected) return;
    loggy.warning("active profile remained absent; stopping VPN instead of retaining an orphaned config");
    final intentEpoch = _beginStopIntent();
    _markUserAction('missing_profile_disconnect', expectsStop: true);
    await _dispatchStopIntent(intentEpoch);
  }

  Future<void> _promoteEmbeddedBootstrapProfileAfterConnection() async {
    final inFlight = _embeddedPromotionInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _promoteEmbeddedBootstrapProfileAfterConnectionInternal();
    _embeddedPromotionInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_embeddedPromotionInFlight, future)) {
        _embeddedPromotionInFlight = null;
      }
    }
  }

  Future<void> _promoteEmbeddedBootstrapProfileAfterConnectionInternal() async {
    if (!PlatformUtils.isMobile) return;
    try {
      final service = ref.read(mobileBootstrapImportServiceProvider);
      if (!await service.hasActiveEmbeddedProfile()) return;
      final embeddedProfileId = ref.read(activeProfileProvider).valueOrNull?.id;
      loggy.info("mobile embedded bootstrap promotion scheduled after CONNECTED");
      await Future<void>.delayed(const Duration(milliseconds: 300));

      var attempt = 0;
      var reachableImportFailures = 0;
      while (true) {
        final delay = attempt < _embeddedPromotionDelays.length
            ? _embeddedPromotionDelays[attempt]
            : _embeddedPromotionSlowRetryDelay;
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
        if (!_canContinueEmbeddedPromotion) return;
        if (!await service.hasActiveEmbeddedProfile()) return;

        final attemptNo = attempt + 1;
        attempt++;
        final canReachBackend = await service.canReachBackend().timeout(
          const Duration(seconds: 6),
          onTimeout: () => false,
        );
        if (!canReachBackend) {
          loggy.warning("mobile embedded bootstrap promotion: backend is not reachable yet [attempt=$attemptNo]");
          continue;
        }

        _embeddedPromotionControlsReconnect = true;
        try {
          final imported = await service.run().timeout(const Duration(seconds: 20), onTimeout: () => false);
          if (!imported) {
            reachableImportFailures++;
            loggy.warning("mobile embedded bootstrap promotion import failed [attempt=$attemptNo]");
            if (reachableImportFailures >= _embeddedPromotionMaxReachableImportFailures) {
              await _disconnectTemporaryEmbeddedProfileAfterReachableBackend();
              return;
            }
            continue;
          }

          final promotedProfile = await _waitForPromotedProfile(embeddedProfileId);
          if (promotedProfile != null && !await service.hasActiveEmbeddedProfile()) {
            await reconnect(promotedProfile);
            loggy.info("mobile embedded bootstrap profile promoted to device profile");
            return;
          }
          reachableImportFailures++;
          loggy.warning(
            "mobile embedded bootstrap promotion import did not switch active profile [attempt=$attemptNo]",
          );
          if (reachableImportFailures >= _embeddedPromotionMaxReachableImportFailures) {
            await _disconnectTemporaryEmbeddedProfileAfterReachableBackend();
            return;
          }
        } finally {
          _embeddedPromotionControlsReconnect = false;
        }
      }
    } catch (e, st) {
      loggy.warning("mobile embedded bootstrap promotion failed", e, st);
    }
  }

  Future<ProfileEntity?> _waitForPromotedProfile(String? embeddedProfileId) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final active = await ref
          .read(profileDataSourceProvider)
          .watchActiveProfile()
          .first
          .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      if (active != null && active.id != embeddedProfileId) {
        return active.toEntity();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  Future<void> _disconnectTemporaryEmbeddedProfileAfterReachableBackend() async {
    final service = ref.read(mobileBootstrapImportServiceProvider);
    if (_isConnected && await service.hasActiveEmbeddedProfile()) {
      loggy.warning(
        "mobile embedded bootstrap promotion exhausted after reachable backend; disconnecting temporary embedded profile",
      );
      final intentEpoch = _beginStopIntent();
      _markUserAction('embedded_profile_cleanup_disconnect', expectsStop: true);
      await _dispatchStopIntent(intentEpoch);
    }
  }

  bool get _isConnected {
    return switch (state) {
      AsyncData(value: final Connected _) => true,
      _ => false,
    };
  }

  bool get _canContinueEmbeddedPromotion {
    return switch (state) {
      AsyncData(value: final Connected _) || AsyncData(value: final Connecting _) => true,
      _ => false,
    };
  }

  Future<void> _connect([int? requestedIntentEpoch]) async {
    final intentEpoch = requestedIntentEpoch ?? _beginStartIntent();
    await _connectThrottled(intentEpoch);
  }

  Future<void> _connectThrottled(int intentEpoch) async {
    if (!_isActiveStartIntent(intentEpoch)) return;
    if (_useMockConnectionFlow) {
      await _mockConnectFlow();
      return;
    }
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (!_isActiveStartIntent(intentEpoch)) return;
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      if (_isCurrentIntent(intentEpoch, running: true)) {
        _desiredRunning = false;
        unawaited(ref.read(Preferences.startedByUser.notifier).update(false));
        state = const AsyncData(Disconnected());
      }
      return;
    }
    _connectedProfileId = activeProfile.id;
    final result = await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).run();
    if (!_isActiveStartIntent(intentEpoch)) return;
    await result.match<Future<void>>(
      (err) async {
        _connectedProfileId = null;
        _desiredRunning = false;
        unawaited(ref.read(Preferences.startedByUser.notifier).update(false));
        _publishConnectionFailure(err, source: "connect");
      },
      (_) async {
        await _resyncFromPlatform(
          "connect_completion",
          intentEpoch: intentEpoch,
          shouldApply: (_) =>
              _isCurrentIntent(intentEpoch, running: true) && _timedOutConnectingIntentEpoch != intentEpoch,
        );
      },
    );
  }

  Future<void> _disconnect(int intentEpoch, {bool force = false}) async {
    if (_useMockConnectionFlow) {
      await _mockDisconnectFlow();
      return;
    }
    if (!_isCurrentIntent(intentEpoch, running: false)) return;
    state = const AsyncData(Disconnecting());
    final result = await _connectionRepo.disconnect(force: force).run();
    if (!_isCurrentIntent(intentEpoch, running: false)) return;
    final failure = result.getLeft().toNullable();
    if (failure != null) {
      _publishConnectionFailure(failure, source: "disconnect");
      return;
    }
    final authoritative = await _resyncFromPlatform(
      "disconnect_completion",
      intentEpoch: intentEpoch,
      shouldApply: (status) => _isCurrentIntent(intentEpoch, running: false) && status is Disconnected,
    );
    // null is not proof that Android released the TUN. Keep Disconnecting so
    // the bounded watchdog can either observe DISCONNECTED or expose a
    // retryable error instead of falsely presenting the VPN as stopped.
    if (authoritative == null) {
      loggy.warning("disconnect completed without an authoritative terminal snapshot [intent=$intentEpoch]");
    }
  }

  void _publishConnectionFailure(ConnectionFailure failure, {required String source}) {
    loggy.warning("connection lifecycle failure [$source]", failure);
    _releaseMainButtonStart();
    unawaited(ref.read(errorReportControllerProvider).captureConnectionFailure(failure, StackTrace.current));
    state = AsyncError(failure, StackTrace.current);

    final t = ref.read(translationsProvider).requireValue;
    unawaited(
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErrWithDiagnostic(failure.present(t), diagnosticText: t.diagnosticError(failure)),
    );
    if (failure.toString().contains("panic")) {
      unawaited(Sentry.captureException(Exception(failure.toString())));
    }
  }

  Future<void> _mockConnectFlow() async {
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("mock connect skipped: no active profile");
      return;
    }

    state = const AsyncData(Connecting());
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    _mockConnectAttempts += 1;
    final shouldFail = _mockConnectAttempts % 3 == 0;
    if (shouldFail) {
      const err = ConnectionFailure.unexpected("Mock connection failed");
      await ref.read(Preferences.startedByUser.notifier).update(false);
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErrWithDiagnostic(
            err.present(ref.read(translationsProvider).requireValue),
            diagnosticText: ref.read(translationsProvider).requireValue.diagnosticError(err),
          );
      state = AsyncError(err, StackTrace.current);
      return;
    }

    state = const AsyncData(Connected());
  }

  Future<void> _mockDisconnectFlow() async {
    state = const AsyncData(Disconnecting());
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    state = const AsyncData(Disconnected());
  }

  Future<void> _mockReconnectFlow() async {
    state = const AsyncData(Connecting());
    await Future<void>.delayed(const Duration(milliseconds: 2400));
    state = const AsyncData(Connected());
  }

  void _markUserAction(String action, {bool expectsStop = false}) {
    _lastUserAction = action;
    _lastUserActionAt = DateTime.now().toUtc();
    if (expectsStop) {
      _expectedStopIntentEpoch = _connectionIntentEpoch;
    }
  }

  bool get _hasExpectedStopIntent => _expectedStopIntentEpoch == _connectionIntentEpoch;

  bool _shouldCaptureUnexpectedDisconnect(
    Disconnected disconnected, {
    required bool wasUpBefore,
    required bool expectedRunning,
    required VpnSessionSnapshot? nativeSnapshot,
  }) {
    if (!shouldCaptureUnexpectedDisconnect(
      wasUpBefore: wasUpBefore,
      expectedRunning: expectedRunning,
      hasFailure: disconnected.connectionFailure != null,
      hasExpectedStopIntent: _hasExpectedStopIntent,
      nativeSnapshot: nativeSnapshot,
    )) {
      return false;
    }

    if (PlatformUtils.isIOS && disconnected.connectionFailure == null) {
      loggy.info("iOS VPN disconnected without failure; treating as external user stop");
      return false;
    }

    return true;
  }
}

/// Returns true only for a non-terminal stop-looking callback that belongs to
/// the preparation/replacement work of the currently desired Start.
///
/// Real failures and explicit system stops remain authoritative. A Flutter
/// stop cannot be newer while [desiredRunning] is true: dispatching a newer
/// local Stop flips that intent synchronously before the platform callback can
/// arrive.
@visibleForTesting
bool shouldIgnoreTransientStopDuringStart({
  required bool? desiredRunning,
  required ConnectionStatus status,
  required VpnSessionSnapshot? nativeSnapshot,
}) {
  if (desiredRunning != true || (status is! Disconnecting && status is! Disconnected)) return false;
  if (status case Disconnected(connectionFailure: final _?)) return false;
  if (nativeSnapshot == null || nativeSnapshot.phase == VpnSessionPhase.failed) return false;
  return nativeSnapshot.requestedAction == 'connect' ||
      nativeSnapshot.requestedAction == 'prepare' ||
      nativeSnapshot.stopSource == VpnStopSource.replacement ||
      nativeSnapshot.stopSource == VpnStopSource.flutter;
}

@visibleForTesting
bool shouldFailClosedMainButtonSnapshotResync({required bool isMobile}) => isMobile;

/// Decides whether reaching [Disconnected] is an outage worth reporting.
///
/// An expected stop must be backed by an explicit notifier intent or by the
/// authoritative Android session snapshot. UI [Disconnecting] and Dart-side
/// `CoreStopping` are mutable local projections and are not evidence by
/// themselves.
///
/// Explicit failure evidence wins over stop intent. A teardown that reaches
/// native `FAILED`, or a disconnected status carrying [ConnectionFailure], is
/// still a real incident even if it happened during stop/restart handling.
@visibleForTesting
bool shouldCaptureUnexpectedDisconnect({
  required bool wasUpBefore,
  required bool expectedRunning,
  required bool hasFailure,
  required bool hasExpectedStopIntent,
  required VpnSessionSnapshot? nativeSnapshot,
}) {
  if (!wasUpBefore) return false;
  if (hasFailure || nativeSnapshot?.phase == VpnSessionPhase.failed) return true;
  if (!expectedRunning) return false;
  if (hasExpectedStopIntent || nativeSnapshotIndicatesExplicitStop(nativeSnapshot)) return false;
  return true;
}

@visibleForTesting
bool nativeSnapshotIndicatesExplicitStop(VpnSessionSnapshot? snapshot) {
  if (snapshot == null || snapshot.requestedAction != 'stop') return false;
  final stopInProgressOrComplete = switch (snapshot.phase) {
    VpnSessionPhase.stopRequested || VpnSessionPhase.stopping || VpnSessionPhase.disconnected => true,
    _ => false,
  };
  if (!stopInProgressOrComplete) return false;
  return switch (snapshot.stopSource) {
    VpnStopSource.flutter ||
    VpnStopSource.system ||
    VpnStopSource.notification ||
    VpnStopSource.tile ||
    VpnStopSource.shortcut ||
    VpnStopSource.revoke ||
    VpnStopSource.replacement => true,
    VpnStopSource.none || VpnStopSource.destroy || VpnStopSource.internal || VpnStopSource.unknown => false,
  };
}

@visibleForTesting
bool shouldReconnectForActiveProfileChange({
  required bool connected,
  required String? connectedProfileId,
  required String? nextProfileId,
}) {
  return connected && connectedProfileId != nextProfileId;
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}
