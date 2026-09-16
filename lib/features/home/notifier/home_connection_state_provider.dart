import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/utils/platform_utils.dart';

/// One runtime projection for the Home button and its animated background.
/// This retains the existing platform sources and adds no polling or commands.
final homeConnectionStateProvider = Provider<MainVpnButtonState>((ref) {
  final connection = ref.watch(connectionNotifierProvider);
  final snapshot = ref.watch(mainVpnButtonStateProvider);
  return PlatformUtils.isAndroid
      ? snapshot.valueOrNull ?? const MainVpnButtonState.loading()
      : MainVpnButtonState.fromLegacyConnectionStatus(connection.valueOrNull);
});
