import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zeon/core/localization/translations.dart';
import 'package:zeon/core/preferences/general_preferences.dart';
import 'package:zeon/core/preferences/preferences_provider.dart';
import 'package:zeon/core/theme/app_theme.dart';
import 'package:zeon/core/theme/app_theme_mode.dart';
import 'package:zeon/core/widget/keyboard_focus_outline.dart';
import 'package:zeon/core/widget/tv_display_layout.dart';
import 'package:zeon/features/per_app_proxy/model/app_package_info.dart';
import 'package:zeon/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:zeon/features/per_app_proxy/model/pkg_flag.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:zeon/features/per_app_proxy/overview/per_app_proxy_page.dart';
import 'package:zeon/gen/translations_ru.g.dart';

const _capture = ValueKey('per-app-capture');
final _outline = find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.foregroundPainter is KeyboardFocusOutlinePainter,
);

Finder _row(String name) => find.ancestor(of: find.text(name), matching: find.byType(CheckboxListTile));

bool _focusInside(Finder finder) {
  final target = finder.evaluate().single;
  final context = FocusManager.instance.primaryFocus?.context;
  var inside = context == target;
  context?.visitAncestorElements((ancestor) {
    if (ancestor == target) inside = true;
    return !inside;
  });
  return inside;
}

void _focusRow(Finder finder) {
  final target = finder.evaluate().single;
  FocusManager.instance.rootScope.descendants.firstWhere((node) {
    if (!node.canRequestFocus || node.skipTraversal || node.context == null) return false;
    var inside = node.context == target;
    node.context!.visitAncestorElements((ancestor) {
      if (ancestor == target) inside = true;
      return !inside;
    });
    return inside;
  }).requestFocus();
}

Future<_SelectedApps> _pumpPage(WidgetTester tester, AppThemeMode mode, {bool television = true}) async {
  tester.view.physicalSize = television ? const Size(960, 540) : const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final selected = _SelectedApps();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWith((_) => preferences),
      translationsProvider.overrideWith((_) => TranslationsRu()),
      perAppProxyProvider(AppProxyMode.exclude).overrideWith(() => selected),
    ],
  );
  addTearDown(container.dispose);
  await container.read(sharedPreferencesProvider.future);
  await container.read(translationsProvider.future);
  await container.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
  await container.read(perAppProxyProvider(AppProxyMode.exclude).future);
  final theme = AppTheme(mode, 'Montserrat');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _capture,
        child: TvDisplayLayout(
          isTelevision: television,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: mode == AppThemeMode.light ? theme.lightTheme(null) : theme.darkTheme(null),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            locale: const Locale('ru'),
            supportedLocales: const [Locale('ru')],
            home: const _ApplicationsPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return selected;
}

Future<void> _capturePage(WidgetTester tester, String name) async {
  final folder = Platform.environment['ZEON_UI_EVIDENCE'];
  if (folder == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(folder).create(recursive: true);
    await File('$folder/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<Color> _pixelAt(WidgetTester tester, Offset point) async {
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
    final image = await boundary.toImage();
    final bytes = (await image.toByteData())!;
    final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
    final color = Color.fromARGB(
      bytes.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
    image.dispose();
    return color;
  }))!;
}

void main() {
  setUpAll(() async {
    for (final entry in jsonDecode(await rootBundle.loadString('FontManifest.json')) as List) {
      final font = entry as Map<String, dynamic>;
      final loader = FontLoader(font['family'] as String);
      for (final asset in font['fonts'] as List) {
        loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
      }
      await loader.load();
    }
  });

  for (final mode in [AppThemeMode.light, AppThemeMode.dark, AppThemeMode.amoled]) {
    testWidgets('bypass rows show remote focus without changing selection in ${mode.name}', (tester) async {
      final selected = await _pumpPage(tester, mode);
      final checked = _row('Example TV');
      final automatic = _row('Example Music');
      _focusRow(checked);
      await tester.pumpAndSettle();
      expect(_focusInside(checked), isTrue);
      expect(_outline, findsOneWidget, reason: 'The entire focused application row needs a visible outline.');
      expect(tester.widget<CheckboxListTile>(checked).value, isTrue);
      await _capturePage(tester, 'per-app-${mode.name}-checked-focus');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_focusInside(automatic), isTrue);
      expect(_outline, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(automatic).value, isNull);
      expect(selected.updates, isEmpty, reason: 'Moving focus must never toggle a routing selection.');
      await _capturePage(tester, 'per-app-${mode.name}-automatic-focus');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected.updates, ['example.music']);
      expect(tester.widget<CheckboxListTile>(automatic).value, isTrue);
      expect(_focusInside(automatic), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_focusInside(checked), isTrue);
      expect(selected.updates, ['example.music']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('bypass hover changes the whole row without selection and touch keeps its appearance', (tester) async {
    final selected = await _pumpPage(tester, AppThemeMode.light, television: false);
    final row = _row('Example Music');
    final sample = tester.getTopLeft(row) + const Offset(8, 30);
    final idle = await _pixelAt(tester, sample);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();
    final hovered = await _pixelAt(tester, sample);
    expect(hovered, isNot(idle), reason: 'Hover must be visible on the row, not only on its checkbox.');
    expect(selected.updates, isEmpty);
    expect(tester.widget<CheckboxListTile>(row).value, isNull);
    await _capturePage(tester, 'per-app-light-mobile-hover');
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(await _pixelAt(tester, sample), idle);
    await tester.tap(find.text('Example Music'));
    await tester.pumpAndSettle();
    expect(selected.updates, ['example.music']);
    expect(_outline, findsNothing, reason: 'Touch must not gain a keyboard-only focus outline.');
    expect(tester.takeException(), isNull);
  });
}

class _ApplicationsPage extends PerAppProxyPage {
  const _ApplicationsPage();

  @override
  Future<Set<AppPackageInfo>> getApps(bool hideSystem) async => {
    const AppPackageInfo(packageName: 'example.tv', name: 'Example TV', icon: null),
    const AppPackageInfo(packageName: 'example.music', name: 'Example Music', icon: null),
    const AppPackageInfo(packageName: 'example.browser', name: 'Example Browser', icon: null),
  };
}

class _SelectedApps extends PerAppProxy {
  final updates = <String>[];

  @override
  Stream<Map<String, int>> build(AppProxyMode? mode) =>
      Stream.value({'example.tv': PkgFlag.userSelection.value, 'example.music': PkgFlag.autoSelection.value});

  @override
  Future<void> updatePkg(String pkg) async {
    updates.add(pkg);
    state = AsyncData({...state.requireValue, pkg: PkgFlag.userSelection.value});
  }
}
