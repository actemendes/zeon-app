import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

const pendingProxySelectionPreferenceKey = 'pending_proxy_selection';
const proxyGroupSnapshotPreferenceKey = 'proxy_group_snapshot_v1';

class PendingProxySelection {
  const PendingProxySelection({required this.groupTag, required this.outboundTag});

  final String groupTag;
  final String outboundTag;

  String encode() => jsonEncode({'group_tag': groupTag, 'outbound_tag': outboundTag});

  static PendingProxySelection? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return null;
      final groupTag = value['group_tag'];
      final outboundTag = value['outbound_tag'];
      if (groupTag is! String || outboundTag is! String) return null;
      if (!_validTag(groupTag) || !_validTag(outboundTag)) return null;
      return PendingProxySelection(groupTag: groupTag, outboundTag: outboundTag);
    } catch (_) {
      return null;
    }
  }

  static bool _validTag(String value) =>
      value.isNotEmpty && value.length <= 512 && !value.contains(RegExp(r'[\x00-\x1f]'));
}

class ProxySelectionPersistence {
  const ProxySelectionPersistence(this.preferences);

  final SharedPreferences preferences;

  PendingProxySelection? readPending() =>
      PendingProxySelection.decode(preferences.getString(pendingProxySelectionPreferenceKey));

  Future<bool> stage(PendingProxySelection selection) =>
      preferences.setString(pendingProxySelectionPreferenceKey, selection.encode());

  Future<bool> clearPending() => preferences.remove(pendingProxySelectionPreferenceKey);

  OutboundGroup? readGroupSnapshot() {
    final raw = preferences.getString(proxyGroupSnapshotPreferenceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return OutboundGroup.fromBuffer(base64Decode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<bool> writeGroupSnapshot(OutboundGroup group) =>
      preferences.setString(proxyGroupSnapshotPreferenceKey, base64Encode(group.writeToBuffer()));
}
