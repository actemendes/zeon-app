import 'package:zeon/zeoncore/zeon_core_service_provider.dart';
import 'package:zeon/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reset_tunnel_notifier.g.dart';

@riverpod
class ResetTunnelNotifier extends _$ResetTunnelNotifier with AppLogger {
  @override
  Future<void> build() async {}

  Future<void> run() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(zeonCoreServiceProvider).resetTunnel().getOrElse((err) {
        loggy.warning("error resetting tunnel", err);
        throw err;
      }).run(),
    );
  }
}
