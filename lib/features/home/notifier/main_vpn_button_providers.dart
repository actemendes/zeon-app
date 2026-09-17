import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/utils/platform_utils.dart';
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
  Future<VpnSessionSnapshot?> resync(String source) => _service.resyncSessionSnapshot(source);
}

final vpnSessionSnapshotSourceProvider = Provider<VpnSessionSnapshotSource>((ref) {
  return ZeonCoreVpnSessionSnapshotSource(ref.watch(zeonCoreServiceProvider));
});

final mainVpnSessionSnapshotProvider = StreamProvider<VpnSessionSnapshot>((ref) async* {
  final source = ref.watch(vpnSessionSnapshotSourceProvider);
  final initial = await source.resync('main_button_subscribe');
  if (initial != null) yield initial;
  yield* source.watch();
});

/// Android UI and foreground data/selection streams share native ownership.
/// Null keeps the existing connection source on platforms without this gate.
final nativeVpnSessionSnapshotProvider = Provider<AsyncValue<VpnSessionSnapshot>?>((ref) {
  final snapshot = ref.watch(mainVpnSessionSnapshotProvider);
  return PlatformUtils.isAndroid ? snapshot : null;
});

final mainVpnButtonStateProvider = Provider<AsyncValue<MainVpnButtonState>>((ref) {
  return ref.watch(mainVpnSessionSnapshotProvider).whenData(MainVpnButtonState.fromSnapshot);
});
