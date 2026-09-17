import 'package:flutter_test/flutter_test.dart';
import 'package:zeon/features/proxy/active/active_proxy_snapshot.dart';
import 'package:zeon/features/proxy/model/proxy_display_name.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  final translations = TranslationsRu();

  test('manual snapshot supplies selected name and flag without exposing opaque ID', () {
    final proxy = activeProxyFromSessionSnapshot(_snapshot(label: '🇩🇪 Server A'))!;
    final display = resolveOutboundDisplayInfo(proxy, translations: translations);
    expect(display.title, 'Server A');
    expect(display.countryCode, 'DE');
    expect(proxy.tag, isNot('opaque-id'));
  });

  for (final separator in ['→', '->', '>', '•']) {
    test('Auto snapshot with $separator supplies concrete leaf', () {
      final proxy = activeProxyFromSessionSnapshot(
        _snapshot(label: 'balance $separator 🇩🇪 Server B', strategy: 'balance'),
      )!;
      final display = resolveOutboundDisplayInfo(proxy, translations: translations);
      expect(display.title, 'Автовыбор • Server B');
      expect(display.countryCode, 'DE');
      expect(proxy.groupSelectedTagDisplay, '🇩🇪 Server B');
    });
  }

  test('matching foreground leaf retains metadata', () {
    final detailed = OutboundInfo(
      tag: 'server-a',
      tagDisplay: 'Server A',
      type: 'proxy',
      isVisible: true,
      urlTestDelay: 42,
    );
    expect(activeProxyFromSessionSnapshot(_snapshot(), activeProxy: detailed), same(detailed));
  });

  test('old leaf and old Auto intent cannot replace the native manual selection', () {
    final stale = OutboundInfo(
      tag: 'balance',
      tagDisplay: 'balance',
      type: 'balancer',
      groupSelectedTagDisplay: 'Server A',
      urlTestDelay: 42,
    );
    final proxy = activeProxyFromSessionSnapshot(_snapshot(), activeProxy: stale)!;
    expect(isAutoSelectedOutbound(proxy), isFalse);
    expect(proxy.hasUrlTestDelay(), isFalse);

    final oldManual = OutboundInfo(tag: 'b', tagDisplay: 'Server B', type: 'proxy', urlTestDelay: 12);
    expect(activeProxyFromSessionSnapshot(_snapshot(), activeProxy: oldManual)!.tagDisplay, 'Server A');
  });

  test('unavailable or unproven native selection never falls back to stale data', () {
    final stale = OutboundInfo(tag: 'a', tagDisplay: 'Server A', type: 'proxy');
    expect(activeProxyFromSessionSnapshot(null, activeProxy: stale), isNull);
    expect(activeProxyFromSessionSnapshot(_snapshot(label: ''), activeProxy: stale), isNull);
    expect(activeProxyFromSessionSnapshot(_snapshot(label: 'select'), activeProxy: stale), isNull);
    expect(activeProxyFromSessionSnapshot(_snapshot(ready: false), activeProxy: stale), isNull);
    expect(activeProxyFromSessionSnapshot(_snapshot(phase: VpnSessionPhase.disconnected), activeProxy: stale), isNull);
  });

  test('Auto without a concrete leaf does not invent a server', () {
    final proxy = activeProxyFromSessionSnapshot(_snapshot(label: 'balance', strategy: 'balance'))!;
    expect(resolveOutboundDisplayInfo(proxy, translations: translations).title, 'Автовыбор');
    expect(proxy.hasGroupSelectedTagDisplay(), isFalse);
  });
}

VpnSessionSnapshot _snapshot({
  String label = 'Server A',
  String strategy = 'selector',
  bool ready = true,
  VpnSessionPhase phase = VpnSessionPhase.connected,
}) => VpnSessionSnapshot(
  generation: 1,
  runtimeEpoch: 'native-test',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: phase,
  coreReady: ready,
  coreStarted: ready,
  commandEndpointReady: ready,
  tunnelReady: ready,
  protectSucceeded: ready,
  selectedOutboundId: 'opaque-id',
  selectedOutboundLabel: label,
  strategy: strategy,
);
