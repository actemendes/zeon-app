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

  test('next startup reloads Auto written outside Flutter after a manual choice', () async {
    const manual = PendingProxySelection(groupTag: 'select', outboundTag: 'server-a');
    const auto = PendingProxySelection(groupTag: 'select', outboundTag: 'balance');
    SharedPreferences.setMockInitialValues({pendingProxySelectionPreferenceKey: manual.encode()});
    final preferences = await SharedPreferences.getInstance();
    final store = ProxySelectionPersistence(preferences);
    expect(store.readPending()?.outboundTag, 'server-a');

    SharedPreferences.setMockInitialValues({pendingProxySelectionPreferenceKey: auto.encode()});
    expect((await store.readPendingFresh())?.outboundTag, 'balance');
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
}
