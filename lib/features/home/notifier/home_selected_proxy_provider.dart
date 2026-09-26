import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/features/proxy/active/active_proxy_snapshot.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

/// The server card and ping must describe the same connected runtime leaf.
final homeSelectedProxyProvider = Provider<OutboundInfo?>((ref) {
  if (!ref.watch(homeConnectionStateProvider).isConnected) return null;
  final activeProxy = ref.watch(activeProxyNotifierProvider).valueOrNull;
  final session = ref.watch(homeVpnSessionSnapshotProvider);
  final proxy = session == null
      ? activeProxy
      : activeProxyFromSessionSnapshot(session.valueOrNull, activeProxy: activeProxy);
  return proxy != null && hasResolvedHomeServer(proxy) ? proxy : null;
});

bool hasResolvedHomeServer(OutboundInfo proxy) {
  if (isAutoSelectedOutbound(proxy)) {
    return displayNameFromRealOutbound(proxy.hasGroupSelectedTagDisplay() ? proxy.groupSelectedTagDisplay : null) !=
            null ||
        displayNameFromRealOutbound(proxy.hasGroupSelectedTag() ? proxy.groupSelectedTag : null) != null ||
        displayNameFromRealOutbound(extractRealOutboundTag(proxy.tagDisplay)) != null;
  }
  return displayNameFromRealOutbound(proxy.tagDisplay) != null;
}
