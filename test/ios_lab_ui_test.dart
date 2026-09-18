import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/features/connection/data/connection_data_providers.dart';
import 'package:zeon/features/connection/model/connection_status.dart';
import 'package:zeon/features/connection/notifier/connection_notifier.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/notifier/main_vpn_button_providers.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/pricing/data/pricing_repository.dart';
import 'package:zeon/features/pricing/model/pricing_models.dart';
import 'package:zeon/features/profile/data/profile_parser.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/notifier/active_profile_notifier.dart';
import 'package:zeon/features/settings/data/config_option_repository.dart';
import 'package:zeon/features/settings/overview/sections/tls_tricks_page.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';

import 'features/ui/approved_interface_test.dart' as ui;
import 'support/ios_vpn_adapter.dart';

// Shared by host widget checks and the explicitly labelled Simulator suite.
void main() {
  testWidgets('SIM05 API failures preserve cached data and stay separate from VPN state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = SharedPreferencesPricingCacheStore(await SharedPreferences.getInstance());
    await cache.writePublic(PricingData(plans: const [], serverTime: DateTime.utc(2026)), DateTime.utc(2026));
    final repository = PricingRepository(
      remoteDataSource: _UnavailableApi(),
      cacheStore: cache,
      deviceAuth: _NoAccount(),
      currentUserId: () => null,
    );
    await expectLater(repository.refreshPricing(), throwsA(isA<PricingRemoteException>()));
    expect((await repository.getCachedPricing())!.source, PricingCatalogSource.publicCache);
    expect(
      pricingFailureType(const PricingRemoteException(type: PricingFailureType.serverUnavailable, statusCode: 503)),
      PricingFailureType.serverUnavailable,
    );
  });
  testWidgets('SIM01 UI connect and disconnect through production notifier', (tester) async {
    final lab = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Connected);
    expect(lab.adapter.connects, 1);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Disconnected);
    expect(lab.adapter.stops, 1);
    await lab.close(tester);
  });

  testWidgets('SIM02 cancel rejects stale callback and allows retry', (tester) async {
    final lab = await _mount(tester);
    final barrier = Completer<void>();
    lab.adapter.startBarrier = barrier;
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Connecting);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Disconnected);
    barrier.complete();
    lab.adapter.emit(const Connected());
    await tester.pump();
    expect(lab.status, isA<Disconnected>());
    // Restore the adapter's authoritative stop after injecting the stale event.
    lab.adapter.emit(const Disconnected());
    lab.adapter.startBarrier = null;
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Connected);
    expect(lab.adapter.connects, 2);
    await lab.close(tester);
  });

  testWidgets('SIM03 profile metadata import feeds the connection owner', (tester) async {
    final parsed = ProfileParser.parse(
      tempFilePath: '',
      profile: ProfileEntity.remote(
        id: 'sim-profile',
        active: true,
        name: '',
        url: 'https://example.invalid/lab#Simulator',
        lastUpdate: DateTime.utc(2026),
      ),
    ).getOrElse((_) => throw StateError('fixture import failed'));
    expect(parsed.name, 'Simulator');
    final lab = await _mount(tester, profile: parsed);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    await _until(tester, () => lab.status is Connected);
    expect(lab.adapter.profiles, ['sim-profile']);
    await lab.close(tester);
  });

  testWidgets('SIM04 settings UI persists a changed value', (tester) async {
    final container = await ui.pumpPage(tester, const TlsTricksPage());
    expect(container.read(ConfigOptions.enableTlsFragment), isFalse);
    await tester.tap(find.text(TranslationsRu().pages.settings.tlsTricks.enable));
    await tester.pumpAndSettle();
    expect(container.read(ConfigOptions.enableTlsFragment), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _UnavailableApi implements PricingRemoteDataSource {
  @override
  Future<PricingData> getPublicPricing() async =>
      throw const PricingRemoteException(type: PricingFailureType.serverUnavailable, statusCode: 503);
  @override
  Future<PricingData> getPersonalizedPricing(String deviceJwt, {bool forceRefresh = false}) => getPublicPricing();
}

class _NoAccount implements PricingDeviceAuth {
  @override
  Future<String> readCachedDeviceJwt() async => '';
  @override
  Future<String> resolveDeviceJwt({bool forceRefresh = false}) async => '';
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
  await tester.pump();
}

class _Profile extends ActiveProfile {
  _Profile(this.profile);
  final ProfileEntity profile;
  @override
  Stream<ProfileEntity?> build() => Stream.value(profile);
}

class _Lab {
  _Lab(this.container, this.adapter);
  final ProviderContainer container;
  final IosVpnAdapter adapter;
  ConnectionStatus? get status => container.read(connectionNotifierProvider).valueOrNull;
  Future<void> close(WidgetTester tester) async {
    await container.read(connectionNotifierProvider.notifier).abortConnection();
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await adapter.dispose();
    await tester.pump(const Duration(seconds: 12));
  }
}

Future<_Lab> _mount(WidgetTester tester, {ProfileEntity? profile}) async {
  SharedPreferences.setMockInitialValues({'haptic_feedback': false, 'started_by_user': false});
  final prefs = await SharedPreferences.getInstance();
  final adapter = IosVpnAdapter();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((ref) => prefs),
      connectionRepositoryProvider.overrideWithValue(adapter),
      vpnSessionSnapshotSourceProvider.overrideWithValue(adapter),
      activeProfileProvider.overrideWith(
        () => _Profile(
          profile ??
              ProfileEntity.local(id: 'sim-fixture', active: true, name: 'Simulator', lastUpdate: DateTime.utc(2026)),
        ),
      ),
    ],
  );
  await container.read(sharedPreferencesProvider.future);
  await container.read(activeProfileProvider.future);
  await container.read(connectionNotifierProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final state = MainVpnButtonState.fromLegacyConnectionStatus(
                ref.watch(connectionNotifierProvider).valueOrNull,
              );
              return MainVpnButtonView(
                presentation: state.present(TranslationsRu()),
                onTap: () => unawaited(
                  ref
                      .read(connectionNotifierProvider.notifier)
                      .handleMainVpnButtonTap(state, confirmStart: () async => true),
                ),
                image: Assets.images.disconnectNorouz,
                useImage: false,
                secureLabel: '',
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Lab(container, adapter);
}
