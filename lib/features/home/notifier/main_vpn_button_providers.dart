import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/utils/utils.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';
import 'package:zeon/zeoncore/zeon_core_service.dart';
import 'package:zeon/zeoncore/zeon_core_service_provider.dart';

abstract interface class VpnSessionSnapshotSource {
  VpnSessionSnapshot? get current;

  Stream<VpnSessionSnapshot> watch();

  Future<VpnSessionSnapshot?> resync(String source);
}

class ZeonCoreVpnSessionSnapshotSource implements VpnSessionSnapshotSource {
  const ZeonCoreVpnSessionSnapshotSource(this._service);

  final ZeonCoreService _service;

  @override
  VpnSessionSnapshot? get current => _service.authoritativeSessionSnapshot;

  @override
  Stream<VpnSessionSnapshot> watch() => _service.watchAuthoritativeSessionSnapshots();

  @override
  Future<VpnSessionSnapshot?> resync(String source) => _service.readAuthoritativeSessionSnapshot();
}

final vpnSessionSnapshotSourceProvider = Provider<VpnSessionSnapshotSource>((ref) {
  return ZeonCoreVpnSessionSnapshotSource(ref.watch(zeonCoreServiceProvider));
});

final class _MainVpnSnapshotProviderLogger with AppLogger {}

final _snapshotProviderLogger = _MainVpnSnapshotProviderLogger();

final mainVpnSessionSnapshotProvider = StreamProvider<VpnSessionSnapshot>((ref) async* {
  final source = ref.watch(vpnSessionSnapshotSourceProvider);
  try {
    final initial = await source.resync('main_button_subscribe');
    if (initial != null) yield initial;
  } catch (error, stackTrace) {
    // A one-shot MethodChannel failure must not terminate the provider: the
    // native event stream remains the long-lived source of truth and can heal
    // the UI as soon as the next snapshot arrives.
    _snapshotProviderLogger.loggy.warning('initial VPN snapshot resync failed', error, stackTrace);
  }
  yield* source.watch();
});

final mainVpnButtonStateProvider = Provider<AsyncValue<MainVpnButtonState>>((ref) {
  return ref.watch(mainVpnSessionSnapshotProvider).whenData(MainVpnButtonState.fromSnapshot);
});
