import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/dialog_notifier.dart';
import 'package:zeon/core/router/go_router/go_router_notifier.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';

final apiVpnRecoveryProvider = Provider<ApiVpnRecoveryCoordinator>(ApiVpnRecoveryCoordinator.new);

/// Coalesces simultaneous API failures into one user decision and one VPN
/// connection attempt.
class ApiVpnRecoveryCoordinator {
  ApiVpnRecoveryCoordinator(this._ref);

  final Ref _ref;
  Future<bool>? _inFlight;
  DateTime? _suppressedUntil;

  Future<bool> recover() {
    final current = _inFlight;
    if (current != null) return current;

    // Startup API probes can happen before MaterialApp owns a navigator. They
    // should fail normally and be retried by ConnectionWrapper once UI exists.
    if (rootNavKey.currentContext == null) return Future<bool>.value(false);
    final suppressedUntil = _suppressedUntil;
    if (suppressedUntil != null && DateTime.now().isBefore(suppressedUntil)) {
      return Future<bool>.value(false);
    }

    final future = _recoverInternal();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<bool> _recoverInternal() async {
    final initial = _ref.read(connectionNotifierProvider).asData?.value;
    if (initial is Connected) return true;

    if (initial is Connecting) {
      return _waitForConnection();
    }

    final t = _ref.read(translationsProvider).requireValue;
    final approved = await _ref
        .read(dialogNotifierProvider.notifier)
        .showConfirmation(
          title: t.dialogs.apiVpnRecovery.title,
          message: t.dialogs.apiVpnRecovery.msg,
          positiveBtnTxt: t.dialogs.apiVpnRecovery.connect,
        );
    if (!approved) {
      _suppressedUntil = DateTime.now().add(const Duration(minutes: 2));
      return false;
    }

    final started = await _ref.read(connectionNotifierProvider.notifier).connectForApiRecovery();
    if (!started) return false;
    final connected = await _waitForConnection();
    if (!connected) {
      _suppressedUntil = DateTime.now().add(const Duration(seconds: 30));
    }
    return connected;
  }

  Future<bool> _waitForConnection({Duration timeout = const Duration(seconds: 35)}) async {
    final deadline = DateTime.now().add(timeout);
    do {
      final state = _ref.read(connectionNotifierProvider);
      if (state.asData?.value case Connected()) return true;
      if (state.hasError) return false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (DateTime.now().isBefore(deadline));
    return false;
  }
}
