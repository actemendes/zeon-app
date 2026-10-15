import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/device/android_tv_provider.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/router/dialog/widgets/zeon_dialog.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/tv_display_layout.dart';
import 'package:zeon/features/mobile/data/external_subscription_sync_service.dart';
import 'package:zeon/features/profile/model/profile_entity.dart';
import 'package:zeon/features/profile/overview/external_subscription_account.dart';
import 'package:zeon/features/profile/overview/tv_subscription_payment_dialog.dart';
import 'package:zeon/features/shortcut/shortcut_wrapper.dart';
import 'package:zeon/gen/translations_ru.g.dart';

import '../ui/approved_interface_test.dart' as fixtures;

final uri = Uri.parse('https://example.com/open/demo?platform=tv#profile');

Future<void> pumpDialog(
  WidgetTester tester, {
  AppThemeMode mode = AppThemeMode.dark,
  Size size = const Size(960, 540),
  double scale = 1,
  Future<ExternalSubscriptionSyncResult> Function()? refresh,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final translations = TranslationsRu();
  final theme = AppTheme(mode, 'Montserrat');
  final container = ProviderContainer(
    overrides: [translationsProvider.overrideWith((_) => Future.value(translations))],
  );
  addTearDown(container.dispose);
  await container.read(translationsProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const ValueKey('capture'),
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: TvDisplayLayout(
              isTelevision: true,
              child: ShortcutWrapper(
                MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
                  locale: const Locale('ru'),
                  supportedLocales: const [Locale('ru')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => showZeonDialog<void>(
                          context,
                          TvSubscriptionPaymentDialog(
                            uri: uri,
                            refresh: refresh ?? () async => ExternalSubscriptionSyncResult.unchanged,
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final fonts = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in fonts) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final asset in font['fonts'] as List) {
        loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
      }
      await loader.load();
    }
  });

  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    testWidgets('TV payment QR fits ${mode.name} and remote OK closes it', (tester) async {
      await pumpDialog(tester, mode: mode);
      expect(
        tester.widget<TvSubscriptionPaymentDialog>(find.byType(TvSubscriptionPaymentDialog)).uri.toString(),
        uri.toString(),
      );
      expect(find.textContaining('правом верхнем'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixtures.capture(tester, 'tv-payment-${mode.name}');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
    });
  }

  testWidgets('large text and low viewport remain scrollable; Back closes', (tester) async {
    await pumpDialog(tester, size: const Size(720, 405), scale: 2);
    expect(tester.takeException(), isNull);
    final qrRect = tester.getRect(find.byType(QrImageView));
    expect(qrRect.top, greaterThanOrEqualTo(0));
    expect(qrRect.bottom, lessThanOrEqualTo(405));
    await fixtures.capture(tester, 'tv-payment-text-2');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
  });

  testWidgets('polling avoids overlap, pauses in background and stops on success/dispose', (tester) async {
    var calls = 0;
    final pending = Completer<ExternalSubscriptionSyncResult>();
    await pumpDialog(
      tester,
      refresh: () {
        calls++;
        return pending.future;
      },
    );
    await tester.pump(const Duration(seconds: 15));
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 1);
    pending.complete(ExternalSubscriptionSyncResult.changed);
    await tester.pumpAndSettle();
    expect(find.text('Подписка обновлена'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 1);
  });

  testWidgets('transient failure retries only in foreground and ends after ten minutes', (tester) async {
    var calls = 0;
    await pumpDialog(
      tester,
      refresh: () {
        calls++;
        return Future.error(StateError('offline'));
      },
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 42; i++) {
      await tester.pump(const Duration(seconds: 15));
    }
    expect(calls, 40);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final isTv in [true, false]) {
    testWidgets('entrypoint uses ${isTv ? "QR" : "browser"} with the same account URL', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      late FakeSync service;
      final profile = RemoteProfileEntity(
        id: 'test-profile',
        active: true,
        name: 'Demo',
        url: 'https://example.com/open/demo?platform=tv',
        lastUpdate: DateTime(2026),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            translationsProvider.overrideWith((_) => Future.value(TranslationsRu())),
            androidTvProvider.overrideWith((_) => Future.value(isTv)),
            externalSubscriptionSyncServiceProvider.overrideWith((ref) => service = FakeSync(ref, prefs)),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(translationsProvider);
                return Scaffold(
                  body: TextButton(
                    onPressed: () => openExternalSubscriptionAccount(context, ref, profile),
                    child: const Text('pay'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('pay'));
      await tester.pumpAndSettle();
      expect(service.browserCalls, isTv ? 0 : 1);
      if (isTv) {
        expect(
          tester.widget<TvSubscriptionPaymentDialog>(find.byType(TvSubscriptionPaymentDialog)).uri.toString(),
          uri.toString(),
        );
        await tester.pump(const Duration(seconds: 15));
        expect(service.expectedId, profile.id);
      } else {
        expect(find.byType(QrImageView), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

class FakeSync extends ExternalSubscriptionSyncService {
  FakeSync(super.ref, super.preferences);
  int browserCalls = 0;
  String? expectedId;
  @override
  Future<bool> openExternalAccount(RemoteProfileEntity? profile) async {
    browserCalls++;
    return true;
  }

  @override
  Future<ExternalSubscriptionSyncResult> refreshSubscription({String? expectedProfileId}) async {
    expectedId = expectedProfileId;
    return ExternalSubscriptionSyncResult.unchanged;
  }
}
