import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';

import '../../tool/runtime_core_snapshot.dart';

void main() {
  final leaf = OutboundInfo(tag: 'Denmark §metadata§', tagDisplay: 'Denmark');
  OutboundGroupList groups(String selected, {List<OutboundInfo>? items}) => OutboundGroupList(
    items: [
      OutboundGroup(
        tag: 'select',
        selected: selected,
        items: items ?? [OutboundInfo(tag: 'balance', isGroup: true), leaf],
      ),
    ],
  );

  test('resolves native Auto group report to the concrete leaf identity', () {
    expect(resolveRuntimeLeaf(groups('balance'), 'balance -> Denmark')?.tag, leaf.tag);
  });

  test('resolves a direct manual report with trimmed technical metadata', () {
    expect(resolveRuntimeLeaf(groups(leaf.tag), 'Denmark')?.tag, leaf.tag);
  });

  test('a group without a leaf and an unknown server are not runtime proof', () {
    expect(resolveRuntimeLeaf(groups('balance'), 'balance'), isNull);
    expect(resolveRuntimeLeaf(groups('balance'), 'balance -> unknown'), isNull);
    expect(resolveRuntimeLeaf(groups('balance'), ''), isNull);
  });

  test('ambiguous display names cannot identify a concrete server', () {
    final ambiguous = groups(
      'balance',
      items: [
        leaf,
        OutboundInfo(tag: 'Denmark §other§'),
      ],
    );
    expect(resolveRuntimeLeaf(ambiguous, 'balance -> Denmark'), isNull);
  });
}
