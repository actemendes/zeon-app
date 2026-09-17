import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  testWidgets('disconnected Home does not render the server picker', (tester) async {
    await _pumpFooter(
      tester,
      status: const Disconnected(),
      activeProxy: OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true),
    );

    expect(find.byKey(const ValueKey('home_server_picker')), findsNothing);
  });

  testWidgets('connected Home keeps the picker visible while the runtime leaf resolves', (tester) async {
    await _pumpFooter(tester, status: const Connected());

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsOneWidget);
  });

  testWidgets('connected Home shows the runtime server name when resolved', (tester) async {
    await _pumpFooter(
      tester,
      status: const Connected(),
      activeProxy: OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true),
    );

    expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
    expect(find.text('Server A'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsNothing);
  });

  for (final legacyStatus in <ConnectionStatus?>[null, const Disconnected()]) {
    testWidgets('Android native session restores card while legacy state is $legacyStatus', (tester) async {
      final source = _SnapshotSource(_snapshot());
      final container = _androidContainer(source, status: legacyStatus);
      addTearDown(container.dispose);
      addTearDown(source.close);

      await _pumpAndroidFooter(tester, container);
      expect(find.byKey(const ValueKey('home_server_picker')), findsOneWidget);
      expect(find.text('Server A'), findsOneWidget);
      expect(find.byKey(const ValueKey('home_server_picker_loading')), findsNothing);

      // Re-enter Home without any foreground proxy/selector/stats emission.
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpAndroidFooter(tester, container);
      expect(find.text('Server A'), findsOneWidget);
      expect(source.resyncCount, 1);

      // Recreate the entire UI container while the native VPN remains alive.
      await tester.pumpWidget(const SizedBox.shrink());
      final reopened = _androidContainer(source, status: legacyStatus);
      addTearDown(reopened.dispose);
      await _pumpAndroidFooter(tester, reopened);
      expect(find.text('Server A'), findsOneWidget);
      expect(source.resyncCount, 2);
    });
  }

  testWidgets('Android native Auto/manual selection wins over stale foreground data', (tester) async {
    final source = _SnapshotSource(_snapshot(label: 'balance → Server B', strategy: 'balance'));
    final container = _androidContainer(
      source,
      status: const Connected(),
      activeProxy: OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true),
    );
    addTearDown(container.dispose);
    addTearDown(source.close);
    await _pumpAndroidFooter(tester, container);
    final autoTitle = '${TranslationsEn().pages.proxies.autoSelection} • Server B';
    expect(find.text(autoTitle), findsOneWidget);
    expect(find.text('Server A'), findsNothing);

    source.snapshots.add(_snapshot(label: 'Server C'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Server C'), findsOneWidget);
    expect(find.text(autoTitle), findsNothing);

    // Native stop must hide the card even while legacy state says Connected.
    source.snapshots.add(_snapshot(phase: VpnSessionPhase.disconnected));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('home_server_picker')), findsNothing);
  });

  testWidgets('Android unconfirmed session does not show stale connected card', (tester) async {
    final source = _SnapshotSource(_snapshot(phase: VpnSessionPhase.verifying));
    final container = _androidContainer(source, status: const Connected());
    addTearDown(container.dispose);
    addTearDown(source.close);
    await _pumpAndroidFooter(tester, container);
    expect(find.byKey(const ValueKey('home_server_picker')), findsNothing);
  });
}

ProviderContainer _androidContainer(
  _SnapshotSource source, {
  required ConnectionStatus? status,
  OutboundInfo? activeProxy,
}) => ProviderContainer(
  overrides: [
    translationsProvider.overrideWith((ref) => TranslationsEn()),
    connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(status)),
    activeProxyNotifierProvider.overrideWith(() => _FixedActiveProxyNotifier(activeProxy)),
    vpnSessionSnapshotSourceProvider.overrideWithValue(source),
    // Exercise the Android branch on the Windows test host.
    homeVpnSessionSnapshotProvider.overrideWith((ref) => ref.watch(mainVpnSessionSnapshotProvider)),
  ],
);

Future<void> _pumpAndroidFooter(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ActiveProxyFooter())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

VpnSessionSnapshot _snapshot({
  String label = 'Server A',
  String strategy = 'selector',
  VpnSessionPhase phase = VpnSessionPhase.connected,
}) => VpnSessionSnapshot(
  generation: 1,
  runtimeEpoch: 'native-test',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: phase,
  coreReady: true,
  coreStarted: true,
  commandEndpointReady: true,
  tunnelReady: true,
  protectSucceeded: true,
  selectedOutboundId: 'opaque-id',
  selectedOutboundLabel: label,
  strategy: strategy,
);

class _SnapshotSource implements VpnSessionSnapshotSource {
  _SnapshotSource(VpnSessionSnapshot initial) : snapshots = BehaviorSubject.seeded(initial);

  final BehaviorSubject<VpnSessionSnapshot> snapshots;
  int resyncCount = 0;

  @override
  VpnSessionSnapshot get current => snapshots.value;

  @override
  Future<VpnSessionSnapshot?> resync(String source) async {
    resyncCount++;
    return current;
  }

  @override
  Stream<VpnSessionSnapshot> watch() => snapshots.stream;

  Future<void> close() => snapshots.close();
}

Future<void> _pumpFooter(WidgetTester tester, {required ConnectionStatus status, OutboundInfo? activeProxy}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        homeVpnSessionSnapshotProvider.overrideWithValue(null),
        connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(status)),
        activeProxyNotifierProvider.overrideWith(() => _FixedActiveProxyNotifier(activeProxy)),
      ],
      child: const MaterialApp(home: Scaffold(body: ActiveProxyFooter())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

class _FixedConnectionNotifier extends ConnectionNotifier {
  _FixedConnectionNotifier(this.status);

  final ConnectionStatus? status;

  @override
  Stream<ConnectionStatus> build() => status == null ? const Stream.empty() : Stream.value(status!);
}

class _FixedActiveProxyNotifier extends ActiveProxyNotifier {
  _FixedActiveProxyNotifier(this.activeProxy);

  final OutboundInfo? activeProxy;

  @override
  Stream<OutboundInfo> build() => activeProxy == null ? const Stream.empty() : Stream.value(activeProxy!);
}
