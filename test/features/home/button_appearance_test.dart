import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/features/button_appearance/data/button_appearance_repository.dart';
import 'package:zeon/features/button_appearance/data/button_image_codec.dart';
import 'package:zeon/features/button_appearance/widget/button_appearance_editor.dart';
import 'package:zeon/features/button_appearance/widget/custom_vpn_button.dart';
import 'package:zeon/features/home/model/main_vpn_button_state.dart';
import 'package:zeon/features/home/widget/connection_button.dart';
import 'package:zeon/gen/assets.gen.dart';
import 'package:zeon/gen/translations_ru.g.dart';
import 'package:zeon/zeoncore/vpn_session_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SharedPreferences preferences;
  late ButtonAppearanceRepository store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('button-appearance-test-');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    store = ButtonAppearanceRepository(preferences, Directory('${temp.path}/images'));
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('standard is default; preset and custom crop survive store recreation', () async {
    expect((await store.load()).preset, ButtonPreset.standard);
    final bytes = File('assets/images/button_presets/anime-idle.png').readAsBytesSync();
    final saved = await store.save(
      ButtonAppearance(
        preset: ButtonPreset.custom,
        name: 'Мой набор',
        pictures: {
          for (final p in ButtonPhase.values)
            p: ButtonPicture(MemoryImage(bytes), zoom: 1.8, alignment: const Alignment(.2, -.4)),
        },
      ),
    );
    expect(saved.pictures.values.first.image, isA<FileImage>());
    expect(await store.directory.list().length, 1); // Shared content is stored once.
    final restarted = await ButtonAppearanceRepository(preferences, store.directory).load();
    expect(restarted.preset, ButtonPreset.custom);
    expect(restarted.name, 'Мой набор');
    expect(restarted.pictures[ButtonPhase.connecting]!.alignment, const Alignment(.2, -.4));
    await store.save(ButtonAppearance(preset: ButtonPreset.kawaii, pictures: restarted.pictures));
    final selected = await store.load();
    expect(selected.preset, ButtonPreset.kawaii);
    expect(selected.complete, isTrue);
  });
  test('invalid configuration, path traversal and missing file fall back safely', () async {
    await preferences.setString(ButtonAppearanceRepository.preferenceKey, '{broken');
    expect((await store.load()).preset, ButtonPreset.standard);
    await preferences.setString(
      ButtonAppearanceRepository.preferenceKey,
      jsonEncode({
        'version': 1,
        'preset': 'custom',
        'name': 'Bad',
        'pictures': {
          for (final p in ButtonPhase.values) p.name: {'file': '../outside.png', 'zoom': 1, 'x': 0, 'y': 0},
        },
      }),
    );
    expect((await store.load()).preset, ButtonPreset.standard);
    await store.save(const ButtonAppearance(preset: ButtonPreset.anime));
    expect((await store.load()).preset, ButtonPreset.anime);
  });
  test('failed write retains previous configuration; cleanup preserves unknown files', () async {
    await store.save(const ButtonAppearance(preset: ButtonPreset.anime));
    final before = preferences.getString(ButtonAppearanceRepository.preferenceKey);
    final obstacle = File('${temp.path}/not-a-directory');
    await obstacle.writeAsString('keep');
    await expectLater(
      ButtonAppearanceRepository(
        preferences,
        Directory(obstacle.path),
      ).save(const ButtonAppearance(preset: ButtonPreset.kawaii)),
      throwsA(isA<FileSystemException>()),
    );
    expect(preferences.getString(ButtonAppearanceRepository.preferenceKey), before);
    final unknown = File('${store.directory.path}/user-file.txt');
    await unknown.writeAsString('keep');
    await store.save(const ButtonAppearance());
    expect(await unknown.readAsString(), 'keep');
  });
  test('incomplete and invalid crops cannot be committed', () async {
    await expectLater(store.save(const ButtonAppearance(preset: ButtonPreset.custom)), throwsFormatException);
    final pictures = {
      for (final p in ButtonPhase.values)
        p: const ButtonPicture(AssetImage('assets/images/button_presets/kawaii-idle.png'), zoom: 4),
    };
    await expectLater(
      store.save(ButtonAppearance(preset: ButtonPreset.custom, pictures: pictures)),
      throwsFormatException,
    );
  });
  test('normalization limits decoded size and rejects corrupt data', () async {
    final bytes = await normalizeButtonImage(File('assets/images/button_presets/anime-idle.png').readAsBytesSync());
    final image = await decodeImageFromList(bytes);
    expect(image.width, lessThanOrEqualTo(768));
    expect(image.height, lessThanOrEqualTo(768));
    image.dispose();
    await expectLater(normalizeButtonImage(utf8.encode('not an image')), throwsA(anything));
  });
  testWidgets('editor removes state gallery and keeps custom slots', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ButtonAppearanceEditor(
          initial: const ButtonAppearance(preset: ButtonPreset.anime),
          onSave: (_) async {},
          animate: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Три состояния'), findsNothing);
    expect(find.text('Котята'), findsNothing);
    expect(find.byType(CustomVpnButton), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preset-custom')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('slot-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-connecting')), findsOneWidget);
    expect(find.byKey(const ValueKey('slot-connected')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('save-appearance'))).onPressed, isNull);
  });
  testWidgets('saving awaits storage, blocks back, then returns to previous page', (tester) async {
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Open'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ButtonAppearanceEditor(
                    initial: const ButtonAppearance(preset: ButtonPreset.anime),
                    animate: false,
                    onSave: (_) async {
                      await Future<void>.delayed(const Duration(milliseconds: 500));
                      saved = true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-appearance')));
    await tester.pump();
    expect(saved, isFalse);
    expect(find.byType(ButtonAppearanceEditor), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(ButtonAppearanceEditor), findsNothing);
  });
  testWidgets('real runtime projection drives images, cancel/stop semantics and reduced motion', (tester) async {
    final semantics = tester.ensureSemantics();
    var calls = 0;
    Future<void> render(VpnSessionPhase phase, {bool reduced = false}) async {
      final snapshot = VpnSessionSnapshot(
        generation: 1,
        runtimeEpoch: 'test',
        sequenceNumber: 1,
        snapshotVersion: 1,
        phase: phase,
        requestedAction: 'connect',
        recoverable: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: MainVpnButtonView(
                presentation: MainVpnButtonState.fromSnapshot(snapshot).present(TranslationsRu()),
                image: Assets.images.disconnectNorouz,
                useImage: false,
                secureLabel: '',
                onTap: () => calls++,
                appearance: const ButtonAppearance(preset: ButtonPreset.anime),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    await render(VpnSessionPhase.verifying);
    await tester.pump(const Duration(seconds: 20));
    expect(tester.widget<CustomVpnButton>(find.byType(CustomVpnButton)).phase, ButtonPhase.connecting);
    await tester.tap(find.byType(CustomVpnButton));
    expect(calls, 1);
    await render(VpnSessionPhase.connected);
    expect(tester.widget<CustomVpnButton>(find.byType(CustomVpnButton)).phase, ButtonPhase.connected);
    expect(find.bySemanticsLabel('Нажмите для отключения'), findsOneWidget);
    await render(VpnSessionPhase.stopping);
    expect(tester.widget<CustomVpnButton>(find.byType(CustomVpnButton)).phase, ButtonPhase.idle);
    expect(tester.widget<CustomVpnButton>(find.byType(CustomVpnButton)).onPressed, isNull);
    expect(find.bySemanticsLabel('Отключение выполняется'), findsOneWidget);
    await render(VpnSessionPhase.failed);
    expect(tester.widget<CustomVpnButton>(find.byType(CustomVpnButton)).phase, ButtonPhase.idle);
    await render(VpnSessionPhase.verifying, reduced: true);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    semantics.dispose();
  });
}
