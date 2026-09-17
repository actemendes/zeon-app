import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

/// A presentation-only outbound from the same native session as the VPN button.
/// selectedOutboundId is an opaque hash, not a selector command tag.
OutboundInfo? activeProxyFromSessionSnapshot(VpnSessionSnapshot? snapshot, {OutboundInfo? activeProxy}) {
  if (snapshot == null || !snapshot.provesConnected) return null;
  final label = snapshot.selectedOutboundLabel.trim();
  if (label.isEmpty) return null;

  final leaf = extractRealOutboundTag(label);
  final isAuto = snapshot.strategy == 'balance' || leaf != null;
  final realName = displayNameFromRealOutbound(leaf ?? label);
  if (activeProxy != null && isAutoSelectedOutbound(activeProxy) == isAuto && realName != null) {
    final activeLabel = isAuto ? activeProxy.groupSelectedTagDisplay : activeProxy.tagDisplay;
    // Preserve details only when they belong to the native selected leaf.
    // Native labels strip private tag suffixes.
    final nativeLabel = activeLabel.trim().split('§').first;
    if (nativeLabel == realName) {
      return activeProxy;
    }
  }
  if (isAuto) {
    return OutboundInfo(
      tag: 'balance',
      tagDisplay: 'balance',
      type: 'balancer',
      isGroup: true,
      isSelected: true,
      isVisible: true,
      groupSelectedTag: realName,
      groupSelectedTagDisplay: realName,
    );
  }
  if (displayNameFromRealOutbound(label) == null) return null;
  return OutboundInfo(tag: label, tagDisplay: label, type: 'proxy', isSelected: true, isVisible: true);
}
