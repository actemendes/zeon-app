import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/notifier/home_connection_state_provider.dart';
import 'package:zeon/features/home/notifier/home_selected_proxy_provider.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/gen/translations_ru.g.dart';
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

  testWidgets('Auto recovery has its own localized loading label', (tester) async {
    expect(TranslationsRu().pages.proxies.selectingBestServer, 'Выбираем лучший сервер');
    expect(TranslationsRu().pages.proxies.restoringConnection, 'Восстанавливаем подключение');
    await _pumpFooter(
      tester,
      status: const Connected(),
      activeProxy: OutboundInfo(
        tag: 'balance',
        tagDisplay: 'balance',
        type: 'balancer',
        isGroup: true,
        isVisible: true,
        groupSelectedTag: 'server-a',
        groupSelectedTagDisplay: 'Server A',
        urlTestStatus: recoveringAutoSearchStatus,
      ),
    );

    expect(find.text(TranslationsEn().pages.proxies.restoringConnection), findsOneWidget);
    expect(find.text('Server A'), findsNothing);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsOneWidget);
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
    expect(container.read(homeConnectionStateProvider).isConnected, isFalse);
    expect(find.byKey(const ValueKey('home_server_picker')), findsNothing);
  });

  testWidgets('Android connected Auto shows progress until its native leaf resolves', (tester) async {
    final source = _SnapshotSource(_snapshot(label: 'balance', strategy: 'balance'));
    final container = _androidContainer(
      source,
      status: const Connected(),
      activeProxy: OutboundInfo(tag: 'balance', tagDisplay: 'balance', type: 'balancer', urlTestDelay: 42),
    );
    addTearDown(container.dispose);
    addTearDown(source.close);

    await _pumpAndroidFooter(tester, container);
    expect(container.read(homeConnectionStateProvider).isConnected, isTrue);
    expect(container.read(homeSelectedProxyProvider), isNull);
    expect(find.text(TranslationsEn().pages.proxies.selectingBestServer), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home_server_picker_loading')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('42 ms'), findsNothing);

    source.snapshots.add(_snapshot(label: 'balance → Server B', strategy: 'balance'));
    await tester.pump();
    await tester.pump();
    expect(find.text('${TranslationsEn().pages.proxies.autoSelection} • Server B'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_server_picker_loading')), findsNothing);
    expect(container.read(homeSelectedProxyProvider)!.hasUrlTestDelay(), isFalse);
    expect(find.text('42 ms'), findsNothing);
  });

  testWidgets('Android ping appears only for the native selected leaf', (tester) async {
    final source = _SnapshotSource(_snapshot(label: 'balance → Server B', strategy: 'balance'));
    final container = _androidContainer(
      source,
      status: const Connected(),
      activeProxy: OutboundInfo(
        tag: 'balance',
        tagDisplay: 'balance',
        type: 'balancer',
        groupSelectedTagDisplay: 'Server B',
        urlTestDelay: 42,
      ),
    );
    addTearDown(container.dispose);
    addTearDown(source.close);
    await _pumpAndroidFooter(tester, container);
    expect(find.text('42 ms'), findsOneWidget);

    source.snapshots.add(_snapshot(label: 'balance → Server C', strategy: 'balance'));
    await tester.pump();
    await tester.pump();
    expect(find.text('42 ms'), findsNothing);
    expect(find.text('${TranslationsEn().pages.proxies.autoSelection} • Server C'), findsOneWidget);
  });

  testWidgets('connected ping slot follows its text width without changing height', (tester) async {
    final updates = BehaviorSubject<OutboundInfo>.seeded(
      OutboundInfo(
        tag: 'server-a',
        tagDisplay: 'Server A',
        type: 'proxy',
        isVisible: true,
        urlTestStatus: 'success',
        urlTestDelay: 42,
        healthScore: 90,
        success: true,
      ),
    );
    addTearDown(updates.close);
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        homeVpnSessionSnapshotProvider.overrideWithValue(null),
        connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(const Connected())),
        activeProxyNotifierProvider.overrideWith(() => _UpdatingActiveProxyNotifier(updates)),
      ],
    );
    addTearDown(container.dispose);

    await _pumpAndroidFooter(tester, container);
    await tester.pump(const Duration(milliseconds: 250));
    final slot = find.byKey(const ValueKey('home_connected_ping_slot'));
    final initialSize = tester.getSize(slot);
    expect(find.text('42 ms'), findsOneWidget);
    expect(initialSize.width, closeTo(36 + tester.getSize(find.text('42 ms')).width, 0.1));
    expect(find.text('Server A'), findsOneWidget);

    updates.add(
      OutboundInfo(tag: 'server-a', tagDisplay: 'Server A', type: 'proxy', isVisible: true, urlTestStatus: 'checking'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(slot).height, initialSize.height);
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.text('...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    final checkingSize = tester.getSize(slot);
    expect(checkingSize.height, initialSize.height);
    expect(checkingSize.width, lessThan(initialSize.width));
    expect(checkingSize.width, closeTo(36 + tester.getSize(find.text('...')).width, 0.1));
    expect(find.text(TranslationsEn().pages.proxies.checkingServers), findsOneWidget);
    expect(find.text('Server A'), findsNothing);
    expect(find.text('...'), findsOneWidget);

    updates.add(
      OutboundInfo(
        tag: 'server-b',
        tagDisplay: 'Server B',
        type: 'proxy',
        isVisible: true,
        urlTestStatus: 'success',
        urlTestDelay: 105,
        healthScore: 60,
        success: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    final switchedSize = tester.getSize(slot);
    expect(switchedSize.height, initialSize.height);
    expect(switchedSize.width, greaterThan(checkingSize.width));
    expect(find.text('Server B'), findsOneWidget);
    expect(find.text('105 ms'), findsOneWidget);
    expect(find.text(TranslationsEn().pages.proxies.checkingServers), findsNothing);

    updates.add(
      OutboundInfo(
        tag: 'server-b',
        tagDisplay: 'Server B',
        type: 'proxy',
        isVisible: true,
        urlTestStatus: 'success',
        urlTestDelay: 1234,
        healthScore: 20,
        success: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('1234 ms'), findsOneWidget);
    expect(tester.getSize(slot).width, greaterThan(switchedSize.width));
    expect(tester.getSize(slot).height, initialSize.height);
  });

  testWidgets('mobile ping survives a return to the same result before its fade completes', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    OutboundInfo ping(String status) => OutboundInfo(
      tag: 'server-a',
      tagDisplay: 'Server A',
      type: 'proxy',
      isVisible: true,
      urlTestStatus: status,
      urlTestDelay: status == 'success' ? 96 : 0,
      healthScore: 90,
      success: status == 'success',
    );

    final pingProvider = StateProvider<OutboundInfo>((ref) => ping('success'));
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        homeSelectedProxyProvider.overrideWith((ref) => ref.watch(pingProvider)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Wrap(
                spacing: 14,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [Text('Подключено'), ActiveProxyDelayIndicator(compact: true)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('96 ms'), findsOneWidget);
    container.read(pingProvider.notifier).state = ping('checking');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('...'), findsWidgets);
    container.read(pingProvider.notifier).state = ping('success');
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      container.read(pingProvider.notifier).state = ping(i.isEven ? 'checking' : 'success');
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('96 ms'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('home_connected_ping_slot'))).width, lessThan(150));
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
      child: const MaterialApp(
        home: Scaffold(body: Column(children: [ActiveProxyFooter(), ActiveProxyDelayIndicator(compact: true)])),
      ),
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

class _UpdatingActiveProxyNotifier extends ActiveProxyNotifier {
  _UpdatingActiveProxyNotifier(this.updates);

  final BehaviorSubject<OutboundInfo> updates;

  @override
  Stream<OutboundInfo> build() => updates.stream;
}
