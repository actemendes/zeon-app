import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/widget/app_visual_effects.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/features/home/widget/world_map_background.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preference defaults off and survives a new provider container', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    Future<ProviderContainer> open() async {
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWith((ref) => prefs)]);
      await container.read(sharedPreferencesProvider.future);
      addTearDown(container.dispose);
      return container;
    }

    final first = await open();
    expect(first.read(Preferences.lowPowerMode), isFalse);
    await first.read(Preferences.lowPowerMode.notifier).update(true);
    final second = await open();
    expect(second.read(Preferences.lowPowerMode), isTrue);
    await second.read(Preferences.lowPowerMode.notifier).update(false);
    expect((await open()).read(Preferences.lowPowerMode), isFalse);
  });

  testWidgets('mode stops decorative frames live, preserves VPN actions and restores motion', (tester) async {
    final enabled = ValueNotifier(false);
    final phase = ValueNotifier(VpnSessionPhase.verifying);
    addTearDown(enabled.dispose);
    addTearDown(phase.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: Listenable.merge([enabled, phase]),
          builder: (context, _) {
            final state = MainVpnButtonState.fromSnapshot(
              VpnSessionSnapshot(
                generation: 1,
                runtimeEpoch: 'test',
                sequenceNumber: 1,
                snapshotVersion: 1,
                phase: phase.value,
                requestedAction: 'connect',
                recoverable: true,
              ),
            );
            return AppVisualEffects(
              lowPowerMode: enabled.value,
              child: Scaffold(
                body: Stack(
                  children: [
                    Positioned.fill(child: WorldMapBackground(state: state)),
                    Center(
                      child: MainVpnButtonView(
                        presentation: state.present(TranslationsRu()),
                        onTap: () => taps++,
                        image: Assets.images.disconnectNorouz,
                        useImage: false,
                        secureLabel: '',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    enabled.value = true;
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    ConnectionRingPainter ring() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<ConnectionRingPainter>()
        .single;
    expect(ring().sweep, lessThan(math.pi * 2));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Подключено'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home_connection_button')));
    expect(taps, 1);
    phase.value = VpnSessionPhase.connected;
    await tester.pumpAndSettle();
    expect(ring().sweep, math.pi * 2);
    expect(
      find.byWidgetPredicate((widget) => widget.runtimeType == Text && (widget as Text).data == 'Подключено'),
      findsOneWidget,
    );
    expect(tester.binding.transientCallbackCount, 0);
    enabled.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('disabling mode preserves system reduced motion and media settings', (tester) async {
    late MediaQueryData actual;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          disableAnimations: true,
          textScaler: TextScaler.linear(1.5),
          viewInsets: EdgeInsets.only(bottom: 200),
        ),
        child: AppVisualEffects(
          lowPowerMode: false,
          child: Builder(
            builder: (context) {
              actual = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(actual.disableAnimations, isTrue);
    expect(actual.textScaler.scale(10), 15);
    expect(actual.viewInsets.bottom, 200);
  });
}
