import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/utils/platform_utils.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

/// Android Home surfaces share the same native session, including its outbound.
/// Other platforms retain their existing connection/selector sources.
final homeVpnSessionSnapshotProvider = Provider<AsyncValue<VpnSessionSnapshot>?>((ref) {
  final snapshot = ref.watch(mainVpnSessionSnapshotProvider);
  return PlatformUtils.isAndroid ? snapshot : null;
});

/// One runtime projection for the Home button, server card and background.
/// This retains the existing platform sources and adds no polling or commands.
final homeConnectionStateProvider = Provider<MainVpnButtonState>((ref) {
  final connection = ref.watch(connectionNotifierProvider);
  final snapshot = ref.watch(homeVpnSessionSnapshotProvider);
  return snapshot != null
      ? snapshot.whenData(MainVpnButtonState.fromSnapshot).valueOrNull ?? const MainVpnButtonState.loading()
      : MainVpnButtonState.fromLegacyConnectionStatus(connection.valueOrNull);
});
