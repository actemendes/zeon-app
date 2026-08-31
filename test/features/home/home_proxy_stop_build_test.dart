import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/proxy/active/active_proxy_card.dart';
import 'package:zeon/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:zeon/features/proxy/active/active_proxy_notifier.dart';
import 'package:zeon/zeoncore/generated/v2/hcore/hcore.pb.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  testWidgets('single Home proxy owner survives lazy STOP and START rebuilds', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final proxyBuilds = _BuildCounter();
    late _ControllableConnectionNotifier connection;
    const snapshotSource = _FixedSnapshotSource(_connectedSnapshot);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => preferences),
        translationsProvider.overrideWith((ref) => TranslationsEn()),
        connectionNotifierProvider.overrideWith(() => connection = _ControllableConnectionNotifier()),
        activeProxyNotifierProvider.overrideWith(() => _CountingActiveProxyNotifier(proxyBuilds)),
        vpnSessionSnapshotSourceProvider.overrideWithValue(snapshotSource),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: _TestHomeVpnContent())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(proxyBuilds.value, 1);

    // iOS can publish the replacement STOP and the winning START before
    // Flutter gets another frame. The old activeProxy subscription is still
    // mounted when the final Connected build begins.
    final buildsBeforeCoalescedTransition = proxyBuilds.value;
    connection.publish(const Disconnecting());
    container.invalidate(activeProxyNotifierProvider);
    connection.publish(const Connected());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(proxyBuilds.value, buildsBeforeCoalescedTransition + 1);

    // Keep the old proxy listeners mounted while STOP invalidates their
    // provider. The next frame must remove those dependencies without lazily
    // flushing activeProxy from inside one sibling's build.
    connection.publish(const Disconnecting());
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);

    // The first invalidation may legitimately refresh once while the old
    // listeners are still mounted. After the STOP frame, all three widgets
    // must have removed their proxy dependency, so another lazy invalidation
    // cannot rebuild it.
    final buildsAfterStopFrame = proxyBuilds.value;
    container.invalidate(activeProxyNotifierProvider);
    await tester.pump();
    await tester.pump();
    expect(proxyBuilds.value, buildsAfterStopFrame);

    // START makes the common ancestor resolve the lazy provider before it
    // builds any of the three presentation children. Provider publication may
    // rebuild that ancestor, but can no longer dirty sibling consumers.
    connection.publish(const Connected());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(proxyBuilds.value, greaterThan(buildsAfterStopFrame));
  });
}

class _TestHomeVpnContent extends ConsumerWidget {
  const _TestHomeVpnContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConnected = ref.watch(connectionNotifierProvider.select((value) => value.valueOrNull is Connected));
    final AsyncValue<OutboundInfo> activeProxy = isConnected
        ? ref.watch(activeProxyNotifierProvider)
        : const AsyncLoading();

    return Column(
      children: [
        Column(
          children: [
            ConnectionButton(activeProxy: activeProxy),
            ActiveProxyDelayIndicator(activeProxy: activeProxy),
          ],
        ),
        ActiveProxyFooter(activeProxy: activeProxy),
      ],
    );
  }
}

class _BuildCounter {
  int value = 0;
}

class _ControllableConnectionNotifier extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(const Connected());

  void publish(ConnectionStatus status) {
    state = AsyncData(status);
  }
}

class _CountingActiveProxyNotifier extends ActiveProxyNotifier {
  _CountingActiveProxyNotifier(this.counter);

  final _BuildCounter counter;

  @override
  Stream<OutboundInfo> build() async* {
    counter.value += 1;
    if (!await ref.watch(serviceRunningProvider.future)) return;
    yield OutboundInfo(tag: 'proxy-1', tagDisplay: 'Test Proxy', type: 'proxy', isVisible: true, urlTestDelay: 42);
  }

  @override
  Future<void> urlTest(String? groupTag_) async {}
}

class _FixedSnapshotSource implements VpnSessionSnapshotSource {
  const _FixedSnapshotSource(this.snapshot);

  final VpnSessionSnapshot snapshot;

  @override
  VpnSessionSnapshot get current => snapshot;

  @override
  Future<VpnSessionSnapshot> resync(String source) async => snapshot;

  @override
  Stream<VpnSessionSnapshot> watch() => Stream.value(snapshot);
}

const _connectedSnapshot = VpnSessionSnapshot(
  generation: 1,
  runtimeEpoch: 'home-stop-build-test',
  sequenceNumber: 1,
  snapshotVersion: 1,
  phase: VpnSessionPhase.connected,
  requestedAction: 'connect',
  coreReady: true,
  coreStarted: true,
  commandEndpointReady: true,
  tunnelReady: true,
  protectSucceeded: true,
  platformVpnValidated: true,
  selectedOutboundId: 'proxy-1',
);
