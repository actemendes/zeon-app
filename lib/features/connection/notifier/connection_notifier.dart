import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';
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
import 'package:zeon/features/mobile/data/mobile_bootstrap_import_service.dart';
import 'package:zeon/features/mobile/data/mobile_conn_link_import_service.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/init_signal.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  static const _debugSeedProfileEnabled = bool.fromEnvironment("debug_seed_profile_enabled");
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
  ConnectionStatus? _lastObservedConnectionStatus;

  @override
  Stream<ConnectionStatus> build() async* {
    if (!kIsWeb && Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
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
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    if (_useMockConnectionFlow) {
      yield const Disconnected();
      return;
    }
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
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
      final previousStatus = _lastObservedConnectionStatus;
      _lastObservedConnectionStatus = event;
      loggy.info("connection status: ${event.format()}");
      if (event case Connected() when previousStatus is! Connected) {
        unawaited(_promoteEmbeddedBootstrapProfileAfterConnection());
      }
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (state case AsyncError()) {
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      if (_useMockConnectionFlow) {
        loggy.info("mock reconnect");
        return _mockReconnectFlow();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        final t = ref.read(translationsProvider).requireValue;
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErrWithDiagnostic(err.present(t), diagnosticText: t.diagnosticError(err));
      }).run();
    }
  }

  Future<void> restartForConfigChange(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      if (_useMockConnectionFlow) {
        loggy.info("mock config change restart");
        return _mockReconnectFlow();
      }
      loggy.info("config options changed, restarting connection");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error restarting after config change", err);
        state = AsyncError(err, StackTrace.current);
        final t = ref.read(translationsProvider).requireValue;
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErrWithDiagnostic(err.present(t), diagnosticText: t.diagnosticError(err));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
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
        final canReachBackend = await service
            .canReachBackend(mode: MobileConnLinkImportMode.postConnection)
            .timeout(const Duration(seconds: 6), onTimeout: () => false);
        if (!canReachBackend) {
          loggy.warning("mobile embedded bootstrap promotion: backend is not reachable yet [attempt=$attemptNo]");
          continue;
        }

        final imported = await service
            .run(skipIfAlreadyDone: false, mode: MobileConnLinkImportMode.postConnection)
            .timeout(const Duration(seconds: 20), onTimeout: () => false);
        if (!imported) {
          reachableImportFailures++;
          loggy.warning("mobile embedded bootstrap promotion import failed [attempt=$attemptNo]");
          if (reachableImportFailures >= _embeddedPromotionMaxReachableImportFailures) {
            await _disconnectTemporaryEmbeddedProfileAfterReachableBackend();
            return;
          }
          continue;
        }

        for (var wait = 0; wait < 10; wait++) {
          if (!await service.hasActiveEmbeddedProfile()) {
            loggy.info("mobile embedded bootstrap profile promoted to device profile");
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        reachableImportFailures++;
        loggy.warning("mobile embedded bootstrap promotion import did not switch active profile [attempt=$attemptNo]");
        if (reachableImportFailures >= _embeddedPromotionMaxReachableImportFailures) {
          await _disconnectTemporaryEmbeddedProfileAfterReachableBackend();
          return;
        }
      }
    } catch (e, st) {
      loggy.warning("mobile embedded bootstrap promotion failed", e, st);
    }
  }

  Future<void> _disconnectTemporaryEmbeddedProfileAfterReachableBackend() async {
    final service = ref.read(mobileBootstrapImportServiceProvider);
    if (_isConnected && await service.hasActiveEmbeddedProfile()) {
      loggy.warning(
        "mobile embedded bootstrap promotion exhausted after reachable backend; disconnecting temporary embedded profile",
      );
      await ref.read(Preferences.startedByUser.notifier).update(false);
      await _disconnect();
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

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    await _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    if (_useMockConnectionFlow) {
      await _mockConnectFlow();
      return;
    }
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      final t = ref.read(translationsProvider).requireValue;
      //Go err is not normal object to see the go errors are string and need to be dumped
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErrWithDiagnostic(err.present(t), diagnosticText: t.diagnosticError(err));
      loggy.warning(err);
      if (err.toString().contains("panic")) {
        await Sentry.captureException(Exception(err.toString()));
      }
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  Future<void> _disconnect() async {
    if (_useMockConnectionFlow) {
      await _mockDisconnectFlow();
      return;
    }
    state = const AsyncData(Disconnecting());
    final result = await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      final t = ref.read(translationsProvider).requireValue;
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErrWithDiagnostic(err.present(t), diagnosticText: t.diagnosticError(err));
      state = AsyncError(err, StackTrace.current);
    }).run();
    if (result.isRight()) {
      state = const AsyncData(Disconnected());
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
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}
