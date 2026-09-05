import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/proxy/data/proxy_selection_persistence.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

void main() {
  test('pending proxy selection round-trips and clears atomically', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ProxySelectionPersistence(preferences);
    const selection = PendingProxySelection(groupTag: 'select', outboundTag: 'balance');

    expect(await store.stage(selection), isTrue);
    expect(store.readPending()?.groupTag, 'select');
    expect(store.readPending()?.outboundTag, 'balance');
    expect(await store.clearPending(), isTrue);
    expect(store.readPending(), isNull);
  });

  test('invalid pending selection is rejected without throwing', () async {
    SharedPreferences.setMockInitialValues({pendingProxySelectionPreferenceKey: 'not-json'});
    final preferences = await SharedPreferences.getInstance();

    expect(ProxySelectionPersistence(preferences).readPending(), isNull);
    expect(PendingProxySelection.decode('{"group_tag":"select","outbound_tag":"bad\\nvalue"}'), isNull);
  });

  test('offline outbound group snapshot round-trips protobuf fields', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = ProxySelectionPersistence(preferences);
    final group = OutboundGroup(
      tag: 'select',
      selected: 'balance',
      items: [
        OutboundInfo(tag: 'balance', tagDisplay: 'Auto', type: 'selector', isSelected: true),
        OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy'),
      ],
    );

    expect(await store.writeGroupSnapshot(group), isTrue);
    final restored = store.readGroupSnapshot();
    expect(restored?.tag, 'select');
    expect(restored?.selected, 'balance');
    expect(restored?.items.map((item) => item.tag), ['balance', 'server-a']);
  });

  test('runtime config embeds a valid staged selector without changing other fields', () {
    const selection = PendingProxySelection(groupTag: 'select', outboundTag: 'balance');
    const source =
        '{"route":{"final":"select"},"outbounds":['
        '{"type":"selector","tag":"select","outbounds":["server-a","balance"],"default":"server-a"},'
        '{"type":"direct","tag":"direct"}]}';

    final result = applyProxySelectionToRuntimeConfig(source, selection);
    expect(result, isNotNull);
    final decoded = jsonDecode(result!) as Map<String, dynamic>;
    final selector = (decoded['outbounds'] as List).first as Map<String, dynamic>;
    expect(selector['default'], 'balance');
    expect(selector['zeon_prefer_default'], isTrue);
    expect((decoded['route'] as Map<String, dynamic>)['final'], 'select');
  });

  test('runtime config rejects a stale selection', () {
    const selection = PendingProxySelection(groupTag: 'select', outboundTag: 'missing');
    const source = '{"outbounds":[{"type":"selector","tag":"select","outbounds":["server-a"]}]}';

    expect(applyProxySelectionToRuntimeConfig(source, selection), isNull);
  });
}
